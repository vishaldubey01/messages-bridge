import Foundation
import SQLite3

@main
struct MessagesInboxQueriesTests {
    static func main() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("messages-inbox-tests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        precondition(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { fatalError("Could not create the fixture database") }
        defer { sqlite3_close(database) }

        try execute(database, """
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                display_name TEXT,
                service_name TEXT
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                text TEXT,
                attributedBody BLOB,
                is_from_me INTEGER,
                is_read INTEGER,
                date INTEGER,
                handle_id INTEGER,
                service TEXT
            );
            """)

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func date(daysAgo: Double) -> Int64 {
            Int64(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSinceReferenceDate * 1_000_000_000)
        }

        try execute(database, """
            INSERT INTO handle VALUES (1, '+15550000001'), (2, '+15550000002'), (3, '+15550000003');
            INSERT INTO chat VALUES
                (10, 'iMessage;-;+15550000001', '', 'iMessage'),
                (20, 'iMessage;+;group-guid', 'Weekend plans', 'iMessage'),
                (30, 'iMessage;-;+15550000003', '', 'iMessage');
            INSERT INTO chat_handle_join VALUES (10, 1), (20, 1), (20, 2), (30, 3);

            INSERT INTO message VALUES
                (101, 'Unread direct', NULL, 0, 0, \(date(daysAgo: 1)), 1, 'iMessage'),
                (102, 'Already read', NULL, 0, 1, \(date(daysAgo: 2)), 1, 'iMessage'),
                (103, 'Unread group', NULL, 0, 0, \(date(daysAgo: 3)), 2, 'iMessage'),
                (104, 'Outgoing message', NULL, 1, 0, \(date(daysAgo: 0.25)), NULL, 'iMessage'),
                (105, 'Unread but too old', NULL, 0, 0, \(date(daysAgo: 10)), 3, 'iMessage');
            INSERT INTO chat_message_join VALUES
                (10, 101), (10, 102), (20, 103), (20, 104), (30, 105);
            """)

        let conversations = try MessagesInboxQueries.recentConversations(
            database: database,
            sinceDays: 7,
            limit: 20,
            now: now
        )
        precondition(conversations.count == 2)
        precondition(Set(conversations.map(\.chatID)) == Set([10, 20]))
        precondition(conversations.first(where: { $0.chatID == 10 })?.unreadCount == 1)
        precondition(conversations.first(where: { $0.chatID == 20 })?.unreadCount == 1)

        let unread = try MessagesInboxQueries.unreadMessages(
            database: database,
            sinceDays: 7,
            limit: 20,
            cursorRawDate: nil,
            cursorMessageID: nil,
            now: now
        )
        precondition(unread.rows.map(\.messageID) == [101, 103])
        precondition(!unread.hasMore)
        precondition(unread.rows.allSatisfy { $0.plainText?.hasPrefix("Unread") == true })

        let firstPage = try MessagesInboxQueries.unreadMessages(
            database: database,
            sinceDays: 7,
            limit: 1,
            cursorRawDate: nil,
            cursorMessageID: nil,
            now: now
        )
        precondition(firstPage.rows.map(\.messageID) == [101])
        precondition(firstPage.hasMore)
        let cursor = firstPage.rows[0]
        let secondPage = try MessagesInboxQueries.unreadMessages(
            database: database,
            sinceDays: 7,
            limit: 1,
            cursorRawDate: cursor.rawDate,
            cursorMessageID: cursor.messageID,
            now: now
        )
        precondition(secondPage.rows.map(\.messageID) == [103])
        precondition(!secondPage.hasMore)

        print("Conversation enumeration, unread filtering, and unread pagination passed.")
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(code)"
            sqlite3_free(errorMessage)
            throw NSError(domain: "MessagesInboxQueriesTests", code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }
}
