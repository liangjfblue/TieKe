import AppKit
import SQLite3

struct PinRecord {
    let id: UUID
    let imageName: String
    var frame: CGRect
    let createdAt: Date
    var isOpen: Bool
    var ocrText: String?
    var winTitle: String?
    var processName: String?
}

enum PinStoreError: LocalizedError {
    case database(String)
    case imageEncoding
    case missingImage

    var errorDescription: String? {
        switch self {
        case .database(let detail): return "数据库错误：\(detail)"
        case .imageEncoding: return "图片编码失败。"
        case .missingImage: return "贴图文件不存在。"
        }
    }
}

final class PinStore {
    let root: URL
    private let imageDirectory: URL
    private var database: OpaquePointer?

    init(root: URL? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultRoot = support.appendingPathComponent("TieKe", isDirectory: true)
        if root == nil && !FileManager.default.fileExists(atPath: defaultRoot.path) {
            // 迁移历史目录：中文目录名 → TieKe，更早的 PixPinReplica 同样处理
            for legacy in ["贴刻", "PixPinReplica"] {
                let legacyURL = support.appendingPathComponent(legacy, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    try FileManager.default.moveItem(at: legacyURL, to: defaultRoot)
                    break
                }
            }
        }
        self.root = root ?? defaultRoot
        imageDirectory = self.root.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let path = self.root.appendingPathComponent("pins.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw PinStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS pins (
              id TEXT PRIMARY KEY,
              image_name TEXT NOT NULL,
              x REAL NOT NULL, y REAL NOT NULL,
              width REAL NOT NULL, height REAL NOT NULL,
              created_at REAL NOT NULL,
              is_open INTEGER NOT NULL,
              ocr_text TEXT
            )
            """)
        // 轻量迁移：来源窗口信息列（已存在时静默忽略）
        for sql in ["ALTER TABLE pins ADD COLUMN win_title TEXT",
                    "ALTER TABLE pins ADD COLUMN process_name TEXT"] {
            sqlite3_exec(database, sql, nil, nil, nil)
        }
    }

    deinit { sqlite3_close(database) }

    func save(image: CGImage, frame: CGRect,
              winTitle: String? = nil, processName: String? = nil) throws -> PinRecord {
        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let file = imageDirectory.appendingPathComponent(imageName)
        let data = try ImageExchange.pngData(image)
        try data.write(to: file, options: .atomic)
        let record = PinRecord(id: id, imageName: imageName, frame: frame, createdAt: Date(),
                               isOpen: true, ocrText: nil, winTitle: winTitle, processName: processName)

        do {
            let sql = """
                INSERT INTO pins (id,image_name,x,y,width,height,created_at,is_open,win_title,process_name)
                VALUES (?,?,?,?,?,?,?,1,?,?)
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, to: 1, in: statement)
            bind(imageName, to: 2, in: statement)
            sqlite3_bind_double(statement, 3, frame.minX)
            sqlite3_bind_double(statement, 4, frame.minY)
            sqlite3_bind_double(statement, 5, frame.width)
            sqlite3_bind_double(statement, 6, frame.height)
            sqlite3_bind_double(statement, 7, record.createdAt.timeIntervalSince1970)
            bind(winTitle ?? "", to: 9, in: statement)
            bind(processName ?? "", to: 10, in: statement)
            try step(statement)
            return record
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func openRecords() throws -> [PinRecord] {
        let statement = try prepare("""
            SELECT id,image_name,x,y,width,height,created_at,is_open,ocr_text,win_title,process_name
            FROM pins WHERE is_open=1 ORDER BY created_at
            """)
        defer { sqlite3_finalize(statement) }
        var records: [PinRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawId = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: rawId)),
                  let rawName = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: rawName)
            let frame = CGRect(x: sqlite3_column_double(statement, 2),
                               y: sqlite3_column_double(statement, 3),
                               width: sqlite3_column_double(statement, 4),
                               height: sqlite3_column_double(statement, 5))
            let text = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let winTitle = sqlite3_column_text(statement, 9).map(String.init(cString:)) ?? ""
            let processName = sqlite3_column_text(statement, 10).map(String.init(cString:)) ?? ""
            records.append(PinRecord(id: id, imageName: name, frame: frame,
                                     createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                                     isOpen: true, ocrText: text,
                                     winTitle: winTitle.isEmpty ? nil : winTitle,
                                     processName: processName.isEmpty ? nil : processName))
        }
        return records
    }

    func image(for record: PinRecord) throws -> CGImage {
        let file = imageDirectory.appendingPathComponent(record.imageName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PinStoreError.missingImage }
        return try ImageExchange.load(url: file)
    }

    func replaceImage(_ image: CGImage, for record: PinRecord) throws {
        let file = imageDirectory.appendingPathComponent(record.imageName)
        try ImageExchange.savePNG(image, to: file)
    }

    func updateFrame(_ frame: CGRect, id: UUID) throws {
        let statement = try prepare("UPDATE pins SET x=?,y=?,width=?,height=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, frame.minX)
        sqlite3_bind_double(statement, 2, frame.minY)
        sqlite3_bind_double(statement, 3, frame.width)
        sqlite3_bind_double(statement, 4, frame.height)
        bind(id.uuidString, to: 5, in: statement)
        try step(statement)
    }

    func close(id: UUID) throws {
        let statement = try prepare("UPDATE pins SET is_open=0 WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    func saveOCR(_ text: String, id: UUID) throws {
        let statement = try prepare("UPDATE pins SET ocr_text=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(text, to: 1, in: statement)
        bind(id.uuidString, to: 2, in: statement)
        try step(statement)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PinStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PinStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PinStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
}
