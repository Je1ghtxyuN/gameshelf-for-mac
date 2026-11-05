import Foundation
import CryptoKit
import ImageIO
import Darwin

struct GameMetadataRecord: Codable, Equatable {
    var id: String
    var title: String
    var aliases: [String]
    var image: String
    var source: String
    var page: String
}

/// Private, local metadata only. Immutable cover bytes are committed before the catalog.
/// A failed/crashed write may leave an unreferenced cover, never a partially written catalog.
final class GameMetadataCatalog {
    private struct Document: Codable { var version: Int; var records: [GameMetadataRecord] }
    private let root: URL
    private static let catalogLimit = 4 * 1024 * 1024
    private static let imageLimit = 8 * 1024 * 1024
    private static let recordLimit = 1000
    private struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    init(root: URL) {
        self.root = root
    }

    func match(_ title: String) -> GameMetadataRecord? {
        guard title.utf8.count <= 1024 else { return nil }
        let key = Self.key(title)
        guard !key.isEmpty else { return nil }
        return try? access { metadata, _ in
            let matches = try Self.load(metadata).records.filter {
                ([$0.title] + $0.aliases).contains { Self.key($0) == key }
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    func coverURL(_ record: GameMetadataRecord) -> URL? {
        return try? access { metadata, covers in
            guard try Self.load(metadata).records.contains(record) else { return nil }
            guard Self.filename(record.image) else { return nil }
            let bytes = try Self.read(covers, record.image, limit: Self.imageLimit)
            let ext = try Self.imageExtension(bytes)
            // Generated names bind the bytes to the record, including after an external edit.
            guard record.image == Self.digest(bytes) + "." + ext else { return nil }
            return root.appendingPathComponent("Metadata/Covers").appendingPathComponent(record.image)
        }
    }

    @discardableResult
    func remember(title: String, aliases: [String], imageURL: URL, source: String,
                  page: String, id: String? = nil) throws -> GameMetadataRecord {
        // Validate metadata before opening the caller-selected file.
        var record = GameMetadataRecord(id: id ?? "pending", title: title, aliases: aliases,
                                        image: "pending.png", source: source, page: page)
        try Self.validate(record)
        record.id = id ?? Self.digest(Data((Self.key(title) + "\u{0}" + source + "\u{0}" + page).utf8))
        let bytes = try Self.readURL(imageURL, limit: Self.imageLimit)
        record.image = Self.digest(bytes) + "." + (try Self.imageExtension(bytes))
        return try access(create: true) { metadata, covers in
            var document = try Self.load(metadata)
            let index = document.records.firstIndex(where: { $0.id == record.id })
            if id == nil {
                // Confirmations of the same automatic identity accumulate aliases. Read
                // the previous record under the write lock so concurrent selections merge.
                let previous = index.map { document.records[$0] }
                let candidates = (previous?.aliases ?? []) + (previous.map { [$0.title] } ?? []) + record.aliases
                var seen: Set<String> = [Self.key(record.title)]
                record.aliases = candidates.filter { seen.insert(Self.key($0)).inserted }
                // Reject overflow before publishing either the cover or the document.
                try Self.validate(record)
            }
            if let index {
                document.records[index] = record
            } else {
                guard document.records.count < Self.recordLimit else { throw Invalid("Metadata catalog is full") }
                document.records.append(record)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(document)
            guard encoded.count <= Self.catalogLimit else { throw Invalid("Metadata catalog is too large") }
            if let existing = try Self.readOptional(covers, record.image, limit: Self.imageLimit) {
                guard existing == bytes else { throw Invalid("Cached cover does not match its identity") }
            } else {
                try Self.atomicWrite(bytes, directory: covers, name: record.image, replace: false)
            }
            try Self.atomicWrite(encoded, directory: metadata, name: "catalog.json", replace: true)
            return record
        }
    }

    private static func key(_ title: String) -> String {
        CoverArt.key(title.precomposedStringWithCanonicalMapping)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func text(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func filename(_ value: String) -> Bool {
        value.utf8.count <= 100 && value != "." && value != ".." && !value.isEmpty &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
    }
    private static func validate(_ record: GameMetadataRecord) throws {
        guard filename(record.id), text(record.title, limit: 1024), !key(record.title).isEmpty,
              record.aliases.count <= 64,
              record.aliases.allSatisfy({ text($0, limit: 1024) && !key($0).isEmpty }),
              filename(record.image), text(record.source, limit: 128), text(record.page, limit: 2048),
              let url = URLComponents(string: record.page), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw Invalid("Invalid metadata record") }
    }

    private static func load(_ directory: Int32) throws -> Document {
        guard let data = try readOptional(directory, "catalog.json", limit: catalogLimit) else {
            return Document(version: 1, records: [])
        }
        // Reject unsupported fields instead of accidentally accepting paths or credentials.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "records"],
              let rows = object["records"] as? [[String: Any]], rows.count <= recordLimit,
              rows.allSatisfy({ Set($0.keys) == ["id", "title", "aliases", "image", "source", "page"] }) else {
            throw Invalid("Invalid metadata catalog")
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, Set(document.records.map(\.id)).count == document.records.count else {
            throw Invalid("Unsupported or duplicate metadata records")
        }
        for record in document.records { try validate(record) }
        return document
    }

    private static func imageExtension(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= imageLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let ext = ["public.png": "png", "public.jpeg": "jpg", "org.webmproject.webp": "webp"][type],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw Invalid("Cover must be a complete PNG, JPEG or WebP image, at most 8 MiB and 4096 × 4096 pixels")
        }
        return ext
    }

    // All path components are opened relative to verified descriptors. Never resolve a link
    // and then check its target: even a link to a currently safe directory is rejected.
    private static func components(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), url.path.utf8.count < 4096,
              !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Invalid("Expected a local absolute path")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains("."), !parts.contains("..") else { throw Invalid("Invalid path component") }
        return parts
    }
    private static func directory(_ parent: Int32, _ name: String, create: Bool) throws -> Int32 {
        if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw Invalid("Cannot create metadata directory") }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Invalid("Unsafe or unavailable metadata directory") }
        return descriptor
    }
    private static func openDirectory(_ parts: [String], create: Bool) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Invalid("Cannot open filesystem root") }
        do {
            for part in parts {
                let next = try directory(descriptor, part, create: create)
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private func access<T>(create: Bool = false, _ body: (Int32, Int32) throws -> T) throws -> T {
        let base = try Self.openDirectory(Self.components(root), create: create)
        defer { close(base) }
        let metadata = try Self.directory(base, "Metadata", create: create)
        defer { close(metadata) }
        // Darwin can return ENOENT while another opener is creating the same vnode.
        // Use exclusive creation and retry only this bounded, benign creation race.
        var lock: Int32 = -1
        for _ in 0..<8 {
            lock = openat(metadata, ".catalog.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if lock >= 0 { break }
            guard errno == ENOENT else { throw Invalid("Cannot open metadata lock") }
            lock = openat(metadata, ".catalog.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            if lock >= 0 { break }
            guard errno == EEXIST || errno == ENOENT else { throw Invalid("Cannot create metadata lock") }
        }
        guard lock >= 0 else { throw Invalid("Cannot open metadata lock") }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(lock, LOCK_EX) == 0 else { throw Invalid("Unsafe metadata lock") }
        defer { flock(lock, LOCK_UN) }
        let covers = try Self.directory(metadata, "Covers", create: create)
        defer { close(covers) }
        return try body(metadata, covers)
    }
    private static func readURL(_ url: URL, limit: Int) throws -> Data {
        let parts = try components(url)
        guard let name = parts.last else { throw Invalid("Missing filename") }
        let parent = try openDirectory(Array(parts.dropLast()), create: false)
        defer { close(parent) }
        return try read(parent, name, limit: limit)
    }
    private static func read(_ directory: Int32, _ name: String, limit: Int) throws -> Data {
        guard let bytes = try readOptional(directory, name, limit: limit) else { throw Invalid("Missing metadata file") }
        return bytes
    }
    private static func readOptional(_ directory: Int32, _ name: String, limit: Int) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Invalid("Unsafe or unreadable metadata file")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw Invalid("Unsafe or oversized metadata file") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Invalid("Cannot read metadata file") }
            if count == 0 { break }
            guard result.count + count <= limit else { throw Invalid("Metadata file grew beyond its limit") }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == Int(info.st_size) else { throw Invalid("Metadata file changed during read") }
        return result
    }
    private static func atomicWrite(_ bytes: Data, directory: Int32, name: String, replace: Bool) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard replace, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Invalid("Unsafe metadata destination") }
        } else if errno != ENOENT { throw Invalid("Cannot inspect metadata destination") }
        let temporary = ".write-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Invalid("Cannot create metadata transaction") }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Invalid("Cannot write metadata transaction") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Invalid("Cannot sync metadata transaction") }
        let flags: UInt32 = replace ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(directory, temporary, directory, name, flags) == 0 else { throw Invalid("Cannot publish metadata transaction") }
        guard fsync(directory) == 0 else { throw Invalid("Cannot sync metadata directory") }
    }
}
