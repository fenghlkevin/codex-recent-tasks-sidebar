import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwiftUI

enum TaskRuntimeState: String, Equatable {
    case unknown
    case idle
    case running
    case needsAction
}

enum TaskDisplayState: Equatable {
    case idle
    case running
    case needsAction
    case needsReview

    static func resolve(runtimeState: TaskRuntimeState, hasUnreadUpdate: Bool) -> TaskDisplayState {
        switch runtimeState {
        case .needsAction:
            return .needsAction
        case .running:
            return .running
        case .idle, .unknown:
            return hasUnreadUpdate ? .needsReview : .idle
        }
    }

    var badgeText: String? {
        switch self {
        case .idle:
            return nil
        case .running:
            return "运行中"
        case .needsAction:
            return "待操作"
        case .needsReview:
            return "待查看"
        }
    }

    var statusDescription: String {
        switch self {
        case .idle:
            return "暂无未读更新"
        case .running:
            return "任务正在运行"
        case .needsAction:
            return "任务正在等待操作"
        case .needsReview:
            return "有新回复（待查看）"
        }
    }

    var tintColor: Color {
        switch self {
        case .idle, .running:
            return .accentColor
        case .needsAction:
            return .orange
        case .needsReview:
            return .green
        }
    }
}

struct CodexTask: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let gitBranch: String
    let updatedMillis: Int64
    let rolloutPath: String
    let hasUnreadUpdate: Bool
    let runtimeState: TaskRuntimeState

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cwd
        case gitBranch = "git_branch"
        case updatedMillis = "updated_ms"
        case rolloutPath = "rollout_path"
    }

    init(
        id: String,
        title: String,
        cwd: String,
        gitBranch: String,
        updatedMillis: Int64,
        rolloutPath: String = "",
        hasUnreadUpdate: Bool = false,
        runtimeState: TaskRuntimeState = .unknown
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.updatedMillis = updatedMillis
        self.rolloutPath = rolloutPath
        self.hasUnreadUpdate = hasUnreadUpdate
        self.runtimeState = runtimeState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        gitBranch = try container.decode(String.self, forKey: .gitBranch)
        updatedMillis = try container.decode(Int64.self, forKey: .updatedMillis)
        rolloutPath = try container.decodeIfPresent(String.self, forKey: .rolloutPath) ?? ""
        hasUnreadUpdate = false
        runtimeState = .unknown
    }

    var deepLink: URL? {
        URL(string: "codex://threads/\(id)")
    }

    var canonicalProjectPath: String {
        URL(fileURLWithPath: cwd)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    var projectName: String {
        let name = URL(fileURLWithPath: canonicalProjectPath).lastPathComponent
        return name.isEmpty ? "未归类" : name
    }

    var displayState: TaskDisplayState {
        TaskDisplayState.resolve(runtimeState: runtimeState, hasUnreadUpdate: hasUnreadUpdate)
    }

    func replacingTitle(with newTitle: String) -> CodexTask {
        CodexTask(
            id: id,
            title: newTitle,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: hasUnreadUpdate,
            runtimeState: runtimeState
        )
    }

    func replacingUnreadUpdate(with newValue: Bool) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: newValue,
            runtimeState: runtimeState
        )
    }

    func replacingRuntimeState(with newValue: TaskRuntimeState) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: hasUnreadUpdate,
            runtimeState: newValue
        )
    }
}

private struct ThreadNameRecord: Decodable {
    let id: String
    let threadName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

enum DiagnosticLogger {
    static let logURL: URL = {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("CodexRecentTasksSidebar", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }()

    private static let queue = DispatchQueue(label: "io.github.codexrecenttasks.diagnostics")
    private static let maximumLogSize = 256 * 1024
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        queue.async {
            let timestamp = timestampFormatter.string(from: Date())
            let line = "\(timestamp) \(message)\n"
            let directoryURL = logURL.deletingLastPathComponent()

            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                trimIfNeeded()
                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: logURL.path),
                       let handle = try? FileHandle(forWritingTo: logURL) {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } else {
                        try data.write(to: logURL, options: .atomic)
                    }
                }
            } catch {
                // Diagnostics are best-effort only.
            }
        }
    }

    static func copyLogPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logURL.path, forType: .string)
    }

    static func abbreviatedPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private static func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maximumLogSize else {
            return
        }

        guard let data = try? Data(contentsOf: logURL) else { return }
        let suffix = data.suffix(maximumLogSize / 2)
        try? Data(suffix).write(to: logURL, options: .atomic)
    }
}

private enum UnreadTaskStateRepository {
    private static let persistedAtomsKey = "electron-persisted-atom-state"
    private static let unreadThreadsKey = "unread-thread-ids-by-host-v1"
    private static let maximumFileSize = 64 * 1024 * 1024

    static func loadUnreadThreadIDs() -> Set<String> {
        guard let url = currentGlobalStateURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }
        return unreadThreadIDs(from: data)
    }

    static func unreadThreadIDs(from data: Data) -> Set<String> {
        guard data.count <= maximumFileSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let persistedAtoms = root[persistedAtomsKey] as? [String: Any],
              let unreadThreadsByHost = persistedAtoms[unreadThreadsKey] as? [String: Any] else {
            return []
        }

        var unreadThreadIDs = Set<String>()
        for value in unreadThreadsByHost.values {
            guard let threadIDs = value as? [Any] else { continue }
            for case let threadID as String in threadIDs
                where threadID.count <= 128 && UUID(uuidString: threadID) != nil {
                unreadThreadIDs.insert(threadID)
            }
        }
        return unreadThreadIDs
    }

    private static func currentGlobalStateURL() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_GLOBAL_STATE_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

private final class RolloutTaskStateRepository {
    static let shared = RolloutTaskStateRepository()

    private struct CacheEntry {
        let fileSize: UInt64
        let modificationDate: Date
        let state: TaskRuntimeState
    }

    private struct ReverseScanContext {
        var completedCallIDs = Set<String>()

        mutating func consume(lineData: Data) -> TaskRuntimeState? {
            guard !lineData.isEmpty,
                  lineData.count <= 4 * 1024 * 1024,
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let recordType = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                return nil
            }

            if recordType == "event_msg" {
                switch payloadType {
                case "task_complete", "turn_aborted":
                    return .idle
                case "task_started":
                    return .running
                case "thread/status/changed":
                    guard let status = payload["status"] as? [String: Any],
                          let statusType = status["type"] as? String else {
                        return nil
                    }
                    if statusType == "idle" { return .idle }
                    if statusType == "active" {
                        let flags = status["activeFlags"] as? [String] ?? []
                        return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
                            ? .needsAction
                            : .running
                    }
                default:
                    break
                }
            }

            if recordType == "response_item",
               payloadType == "function_call_output" || payloadType == "custom_tool_call_output",
               let callID = payload["call_id"] as? String {
                completedCallIDs.insert(callID)
                return nil
            }

            if recordType == "response_item",
               payloadType == "function_call" || payloadType == "custom_tool_call",
               let callID = payload["call_id"] as? String {
                let alreadyCompleted = completedCallIDs.remove(callID) != nil
                if !alreadyCompleted && Self.requiresUserAction(payload: payload) {
                    return .needsAction
                }
            }

            return nil
        }

        private static func requiresUserAction(payload: [String: Any]) -> Bool {
            guard let name = payload["name"] as? String else { return false }
            if name == "request_user_input" {
                return true
            }
            guard name == "exec_command" || name == "exec",
                  let rawArguments = (payload["arguments"] as? String) ?? (payload["input"] as? String),
                  rawArguments.utf8.count <= 64 * 1024,
                  let data = rawArguments.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return arguments["sandbox_permissions"] as? String == "require_escalated"
        }
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    func loadState(rolloutPath: String) -> TaskRuntimeState {
        guard let url = validatedRolloutURL(for: rolloutPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSizeNumber = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return .unknown
        }

        let fileSize = fileSizeNumber.uint64Value
        guard fileSize > 0, fileSize <= 512 * 1024 * 1024 else {
            return .unknown
        }

        lock.lock()
        let cached = cache[url.path]
        lock.unlock()
        if let cached,
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return cached.state
        }

        let state = scanState(at: url, fileSize: fileSize)
        lock.lock()
        cache[url.path] = CacheEntry(
            fileSize: fileSize,
            modificationDate: modificationDate,
            state: state
        )
        lock.unlock()
        return state
    }

    static func state(from data: Data) -> TaskRuntimeState {
        var context = ReverseScanContext()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if let state = context.consume(lineData: Data(line)) {
                return state
            }
        }
        return .unknown
    }

    private func scanState(at url: URL, fileSize: UInt64) -> TaskRuntimeState {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unknown
        }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        let maximumBytesToScan: UInt64 = 64 * 1024 * 1024
        var remainingOffset = fileSize
        var scannedBytes: UInt64 = 0
        var carry = Data()
        var context = ReverseScanContext()

        // ponytail: 最多倒查 64 MB，覆盖正常单轮任务；若未来出现超大单轮，再改为增量事件索引。
        while remainingOffset > 0 && scannedBytes < maximumBytesToScan {
            let readLength = min(chunkSize, remainingOffset, maximumBytesToScan - scannedBytes)
            let readOffset = remainingOffset - readLength
            do {
                try handle.seek(toOffset: readOffset)
            } catch {
                return .unknown
            }
            let chunk = handle.readData(ofLength: Int(readLength))
            guard !chunk.isEmpty else { return .unknown }

            var combined = chunk
            combined.append(carry)
            let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex = readOffset == 0 ? 0 : 1
            if lines.count > firstCompleteIndex {
                for index in stride(from: lines.count - 1, through: firstCompleteIndex, by: -1) {
                    if let state = context.consume(lineData: Data(lines[index])) {
                        return state
                    }
                }
            }

            carry = lines.first.map { Data($0) } ?? Data()
            remainingOffset = readOffset
            scannedBytes += readLength
        }

        return .unknown
    }

    private func validatedRolloutURL(for rolloutPath: String) -> URL? {
        guard !rolloutPath.isEmpty, rolloutPath.utf8.count <= 4_096 else { return nil }
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let rootURL: URL
        if let override = environment["CODEX_ROLLOUT_ROOT_OVERRIDE"], !override.isEmpty {
            rootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            rootURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = URL(fileURLWithPath: rolloutPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot + "/"),
              fileManager.isReadableFile(atPath: resolvedURL.path) else {
            return nil
        }
        return resolvedURL
    }
}

struct TaskGroup: Identifiable {
    let id: String
    let name: String
    let tasks: [CodexTask]

    var latestUpdate: Int64 {
        tasks.first?.updatedMillis ?? 0
    }
}

enum ProjectActions {
    static func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInTerminal(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

enum RecentTaskPolicy {
    static let windowHours: Int64 = 48
    static let windowMillis = windowHours * 60 * 60 * 1000

    static func includes(_ task: CodexTask, now: Date) -> Bool {
        let cutoffMillis = Int64(now.timeIntervalSince1970 * 1000) - windowMillis
        return task.updatedMillis >= cutoffMillis
    }
}

enum ReadAcknowledgementPolicy {
    static func apply(to tasks: [CodexTask], acknowledgements: inout [String: Int64]) -> [CodexTask] {
        tasks.map { task in
            guard let acknowledgedMillis = acknowledgements[task.id] else {
                return task
            }
            guard acknowledgedMillis == task.updatedMillis else {
                acknowledgements.removeValue(forKey: task.id)
                return task
            }
            if !task.hasUnreadUpdate {
                acknowledgements.removeValue(forKey: task.id)
                return task
            }
            return task.replacingUnreadUpdate(with: false)
        }
    }
}

enum TaskRepositoryError: LocalizedError {
    case databaseNotFound
    case sqliteFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "没有找到 Codex 本地任务数据库。请先打开并使用一次 Codex。"
        case let .sqliteFailed(message):
            return "读取任务数据库失败：\(message)"
        case let .invalidData(message):
            return "任务数据格式异常：\(message)"
        }
    }

    var isTransientDatabaseOpenError: Bool {
        guard case let .sqliteFailed(message) = self else { return false }
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("unable to open database file")
            || lowercasedMessage.contains("database is locked")
            || lowercasedMessage.contains("disk i/o error")
    }
}

struct TaskRepository {
    private static let query = """
    SELECT
      id,
      CASE WHEN trim(title) = '' THEN '未命名任务' ELSE substr(title, 1, 240) END AS title,
      cwd,
      COALESCE(git_branch, '') AS git_branch,
      CAST(COALESCE(NULLIF(updated_at_ms, 0), updated_at * 1000) AS INTEGER) AS updated_ms,
      COALESCE(rollout_path, '') AS rollout_path
    FROM threads AS task
    WHERE archived = 0
      AND COALESCE(source, '') NOT LIKE '{"subagent"%'
      AND (agent_path IS NULL OR agent_path = '')
      AND NOT EXISTS (
        SELECT 1
        FROM thread_spawn_edges AS edge
        WHERE edge.child_thread_id = task.id
      )
    ORDER BY updated_ms DESC, id ASC;
    """

    static func loadTasks() throws -> (databaseURL: URL, tasks: [CodexTask]) {
        let databaseURLs = try currentDatabaseURLs()
        DiagnosticLogger.log(
            "TaskRepository.loadTasks candidates=\(databaseURLs.map { DiagnosticLogger.abbreviatedPath($0.path) }.joined(separator: ","))"
        )
        var lastError: Error?

        for databaseURL in databaseURLs {
            do {
                let result = try loadTasksWithFallback(from: databaseURL)
                DiagnosticLogger.log(
                    "TaskRepository.loadTasks success database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) taskCount=\(result.tasks.count)"
                )
                return result
            } catch {
                lastError = error
                DiagnosticLogger.log(
                    "TaskRepository.loadTasks failed database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) error=\(error.localizedDescription)"
                )
                guard let repositoryError = error as? TaskRepositoryError,
                      repositoryError.isTransientDatabaseOpenError else {
                    throw error
                }
            }
        }

        throw lastError ?? TaskRepositoryError.databaseNotFound
    }

    private static func loadTasksWithFallback(from databaseURL: URL) throws -> (databaseURL: URL, tasks: [CodexTask]) {
        do {
            return try loadTasks(from: databaseURL, databaseArgument: databaseURL.path, mode: "readonly")
        } catch {
            guard let repositoryError = error as? TaskRepositoryError,
                  repositoryError.isTransientDatabaseOpenError else {
                throw error
            }

            let immutableArgument = "\(databaseURL.absoluteString)?mode=ro&immutable=1"
            DiagnosticLogger.log(
                "TaskRepository.loadTasks immutableFallback database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) reason=\(error.localizedDescription)"
            )
            return try loadTasks(from: databaseURL, databaseArgument: immutableArgument, mode: "immutable")
        }
    }

    private static func loadTasks(from databaseURL: URL, databaseArgument: String, mode: String) throws -> (databaseURL: URL, tasks: [CodexTask]) {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-json",
            "-cmd", ".timeout 800",
            databaseArgument,
            query,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            DiagnosticLogger.log(
                "sqlite3 run failed mode=\(mode) database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) error=\(error.localizedDescription)"
            )
            throw TaskRepositoryError.sqliteFailed(error.localizedDescription)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let rawMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticLogger.log(
                "sqlite3 exit failed mode=\(mode) database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) status=\(process.terminationStatus) stderr=\(message)"
            )
            throw TaskRepositoryError.sqliteFailed(message.isEmpty ? "sqlite3 退出码 \(process.terminationStatus)" : message)
        }

        do {
            let decodedTasks = data.isEmpty ? [] : try JSONDecoder().decode([CodexTask].self, from: data)
            let titleOverrides = loadLatestThreadNames()
            let unreadThreadIDs = UnreadTaskStateRepository.loadUnreadThreadIDs()
            let now = Date()
            let tasks = decodedTasks.map { task in
                let renamedTask = titleOverrides[task.id].map {
                    task.replacingTitle(with: $0)
                } ?? task
                // Codex 按当前任务 ID 标记和清除未读。内部子线程的残留未读不能抬升为顶层任务未读。
                let unreadTask = renamedTask.replacingUnreadUpdate(
                    with: unreadThreadIDs.contains(task.id)
                )
                guard RecentTaskPolicy.includes(unreadTask, now: now) else {
                    return unreadTask
                }
                return unreadTask.replacingRuntimeState(
                    with: RolloutTaskStateRepository.shared.loadState(rolloutPath: unreadTask.rolloutPath)
                )
            }
            return (databaseURL, tasks)
        } catch {
            DiagnosticLogger.log(
                "TaskRepository.decode failed mode=\(mode) database=\(DiagnosticLogger.abbreviatedPath(databaseURL.path)) bytes=\(data.count) error=\(error.localizedDescription)"
            )
            throw TaskRepositoryError.invalidData(error.localizedDescription)
        }
    }

    private static func loadLatestThreadNames() -> [String: String] {
        guard let indexURL = currentSessionIndexURL(),
              let data = try? Data(contentsOf: indexURL) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var namesByID: [String: String] = [:]

        // ponytail: Codex 的 session_index.jsonl 是追加式索引，因此每个 ID 最后一条有效记录即为最新备注。
        // 如果未来改成非追加格式，再升级为解析 updated_at 后比较时间。
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(ThreadNameRecord.self, from: Data(line)),
                  let rawName = record.threadName else {
                continue
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            namesByID[record.id] = name
        }

        return namesByID
    }

    private static func currentSessionIndexURL() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_SESSION_INDEX_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func currentDatabaseURLs() throws -> [URL] {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_TASK_DB_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                DiagnosticLogger.log("TaskRepository.database override missing path=\(DiagnosticLogger.abbreviatedPath(url.path))")
                throw TaskRepositoryError.databaseNotFound
            }
            DiagnosticLogger.log("TaskRepository.database override path=\(DiagnosticLogger.abbreviatedPath(url.path))")
            return [url]
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".codex/state_5.sqlite"),
            home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
        ]
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }

        guard !candidates.isEmpty else {
            DiagnosticLogger.log("TaskRepository.database candidates missing")
            throw TaskRepositoryError.databaseNotFound
        }
        if candidates.count > 1 {
            DiagnosticLogger.log(
                "TaskRepository.database newestOnly selected=\(DiagnosticLogger.abbreviatedPath(candidates[0].path)) ignored=\(candidates.dropFirst().map { DiagnosticLogger.abbreviatedPath($0.path) }.joined(separator: ","))"
            )
        }
        return [candidates[0]]
    }

    static func currentDatabaseURLForUsageAnalytics() throws -> URL {
        try currentDatabaseURLs()[0]
    }

    private static func modificationDate(for url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}

enum TimeLabelFormatter {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func shortLabel(milliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let elapsed = max(0, now.timeIntervalSince(date))

        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3600 {
            return "\(max(1, Int(elapsed / 60))) 分钟"
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(clockFormatter.string(from: date))"
        }
        return monthDayFormatter.string(from: date)
    }

    static func fullLabel(milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return fullFormatter.string(from: date)
    }
}

enum WindowDisplayMode: String {
    case docked
    case pinned
}

enum DockSide: String {
    case left
    case right

    var label: String {
        self == .left ? "左侧" : "右侧"
    }
}

enum DockPlacement {
    static let gap: CGFloat = 8
    static let trackingInterval: TimeInterval = 1.0 / 30.0
    static let movementTolerance: CGFloat = 0.5
    static let sizeTolerance: CGFloat = 0.5
    static let rapidShrinkAreaRatio: CGFloat = 0.72
    static let rapidShrinkDimensionDelta: CGFloat = 24
    static let rapidShrinkInterval: TimeInterval = 0.25

    static func targetPanelSize(
        codexFrame: NSRect,
        currentPanelSize: NSSize,
        minPanelSize: NSSize,
        maxPanelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSSize {
        let targetHeight = min(
            max(minPanelSize.height, codexFrame.height),
            min(maxPanelSize.height, visibleFrame.height)
        )
        return NSSize(width: currentPanelSize.width, height: targetHeight)
    }

    static func targetOrigin(
        codexFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        side: DockSide
    ) -> NSPoint {
        let targetX: CGFloat
        switch side {
        case .left:
            let leftOutsideX = codexFrame.minX - panelSize.width - gap
            let rightOutsideX = codexFrame.maxX + gap
            if leftOutsideX >= visibleFrame.minX {
                targetX = leftOutsideX
            } else if rightOutsideX + panelSize.width <= visibleFrame.maxX {
                targetX = rightOutsideX
            } else {
                targetX = min(
                    max(visibleFrame.minX, codexFrame.minX + gap),
                    visibleFrame.maxX - panelSize.width
                )
            }
        case .right:
            let rightOutsideX = codexFrame.maxX + gap
            let leftOutsideX = codexFrame.minX - panelSize.width - gap
            if rightOutsideX + panelSize.width <= visibleFrame.maxX {
                targetX = rightOutsideX
            } else if leftOutsideX >= visibleFrame.minX {
                targetX = leftOutsideX
            } else {
                targetX = min(
                    max(visibleFrame.minX, codexFrame.maxX - panelSize.width - gap),
                    visibleFrame.maxX - panelSize.width
                )
            }
        }

        let alignedTopY = codexFrame.maxY - panelSize.height
        let targetY = min(
            max(visibleFrame.minY, alignedTopY),
            visibleFrame.maxY - panelSize.height
        )
        return NSPoint(x: targetX, y: targetY)
    }

    static func dockingScreen(for codexFrame: NSRect, screens: [NSScreen]) -> NSScreen? {
        screens.max { lhs, rhs in
            lhs.frame.intersection(codexFrame).area < rhs.frame.intersection(codexFrame).area
        }
    }
}

enum WindowWidthPreset: Int, CaseIterable {
    case narrow = 320
    case medium = 380
    case wide = 500

    static let storageKey = "CodexRecentTasksWindowWidthPreset"

    var title: String {
        switch self {
        case .narrow: return "窄"
        case .medium: return "中"
        case .wide: return "宽"
        }
    }

    static var saved: WindowWidthPreset {
        let rawValue = UserDefaults.standard.integer(forKey: storageKey)
        return WindowWidthPreset(rawValue: rawValue) ?? .medium
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

@MainActor
final class WindowModeModel: ObservableObject {
    @Published private(set) var mode: WindowDisplayMode = .docked
    @Published private(set) var dockSide: DockSide
    @Published fileprivate(set) var statusText = "正在查找 Codex 窗口"

    var onModeChange: ((WindowDisplayMode) -> Void)?
    var onDockSideChange: ((DockSide) -> Void)?
    var onPinnedDrag: ((CGSize, Bool) -> Void)?

    init() {
        let savedSide = UserDefaults.standard.string(forKey: "CodexRecentTasksDockSide")
        dockSide = DockSide(rawValue: savedSide ?? "") ?? .right
    }

    func select(_ newMode: WindowDisplayMode) {
        mode = newMode
        onModeChange?(newMode)
    }

    func selectDockSide(_ newSide: DockSide) {
        setDockSide(newSide, notify: true)
    }

    func observeDockSide(_ newSide: DockSide) {
        setDockSide(newSide, notify: false)
    }

    func dragPinnedWindow(translation: CGSize, ended: Bool) {
        onPinnedDrag?(translation, ended)
    }

    private func setDockSide(_ newSide: DockSide, notify: Bool) {
        guard dockSide != newSide else { return }
        dockSide = newSide
        UserDefaults.standard.set(newSide.rawValue, forKey: "CodexRecentTasksDockSide")
        if notify {
            onDockSideChange?(newSide)
        }
    }
}

enum CodexWindowLocator {
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func isCodexRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.openai.codex"
        }
    }

    static func isCodexMiniaturized() -> Bool {
        guard hasAccessibilityPermission() else {
            return false
        }

        guard let codex = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex"
        }) else {
            return false
        }

        let appElement = AXUIElementCreateApplication(codex.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return false
        }

        return windows.allSatisfy { window in
            var minimizedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success else {
                return false
            }
            return (minimizedValue as? Bool) == true
        }
    }

    static func largestWindowFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let quartzFrames = windows.compactMap { info -> CGRect? in
            guard
                let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                layerNumber.intValue == 0,
                let runningApplication = NSRunningApplication(processIdentifier: pid_t(pidNumber.int32Value)),
                runningApplication.bundleIdentifier == "com.openai.codex",
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                width >= 500,
                height >= 320
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        guard let quartzFrame = quartzFrames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? quartzFrame.maxY
        return NSRect(
            x: quartzFrame.minX,
            y: primaryScreenHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var databasePath = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var now = Date()

    typealias RefreshCompletion = () -> Void

    private var refreshTimer: Timer?
    private var runtimeRefreshTimer: Timer?
    private var readAcknowledgements: [String: Int64] = [:]
    private var pendingRefreshRetry: DispatchWorkItem?
    private var transientRefreshFailureCount = 0

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        runtimeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRuntimeStates()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        runtimeRefreshTimer?.invalidate()
        pendingRefreshRetry?.cancel()
    }

    func refresh(completion: RefreshCompletion? = nil) {
        defer { completion?() }
        now = Date()
        do {
            let result = try TaskRepository.loadTasks()
            tasks = ReadAcknowledgementPolicy.apply(
                to: result.tasks,
                acknowledgements: &readAcknowledgements
            )
            databasePath = result.databaseURL.path
            errorMessage = nil
            lastRefresh = Date()
            transientRefreshFailureCount = 0
            pendingRefreshRetry?.cancel()
            pendingRefreshRetry = nil
        } catch {
            if scheduleTransientRetryIfNeeded(for: error) {
                return
            }
            if let repositoryError = error as? TaskRepositoryError,
               repositoryError.isTransientDatabaseOpenError,
               !tasks.isEmpty {
                DiagnosticLogger.log("TaskStore.refresh transientErrorSuppressed=\(error.localizedDescription)")
                errorMessage = nil
                return
            }
            DiagnosticLogger.log("TaskStore.refresh errorShown=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleTransientRetryIfNeeded(for error: Error) -> Bool {
        guard let repositoryError = error as? TaskRepositoryError,
              repositoryError.isTransientDatabaseOpenError,
              transientRefreshFailureCount < 6 else {
            return false
        }

        transientRefreshFailureCount += 1
        pendingRefreshRetry?.cancel()
        errorMessage = nil
        DiagnosticLogger.log(
            "TaskStore.refresh transientRetry attempt=\(transientRefreshFailureCount) error=\(error.localizedDescription)"
        )

        let delay: TimeInterval
        switch transientRefreshFailureCount {
        case 1:
            delay = 0.6
        case 2:
            delay = 1.5
        case 3:
            delay = 3.0
        case 4:
            delay = 6.0
        default:
            delay = 10.0
        }

        let retry = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingRefreshRetry = nil
                self?.refresh()
            }
        }
        pendingRefreshRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
        return true
    }

    func refreshRuntimeStates() {
        now = Date()
        let refreshedTasks = tasks.map { task in
            guard RecentTaskPolicy.includes(task, now: now) else { return task }
            let state = RolloutTaskStateRepository.shared.loadState(rolloutPath: task.rolloutPath)
            return task.replacingRuntimeState(with: state)
        }
        if refreshedTasks != tasks {
            tasks = refreshedTasks
        }
    }

    func groups(matching searchText: String) -> [TaskGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentTasks = tasks.filter { RecentTaskPolicy.includes($0, now: now) }
        let visibleTasks: [CodexTask]
        if query.isEmpty {
            visibleTasks = recentTasks
        } else {
            visibleTasks = recentTasks.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.projectName.localizedCaseInsensitiveContains(query)
                    || $0.gitBranch.localizedCaseInsensitiveContains(query)
            }
        }

        let grouped = Dictionary(grouping: visibleTasks, by: \CodexTask.canonicalProjectPath)
        return grouped.map { path, projectTasks in
            let sorted = projectTasks.sorted {
                if $0.updatedMillis == $1.updatedMillis { return $0.id < $1.id }
                return $0.updatedMillis > $1.updatedMillis
            }
            return TaskGroup(id: path, name: sorted.first?.projectName ?? "未归类", tasks: sorted)
        }.sorted {
            if $0.latestUpdate == $1.latestUpdate { return $0.name < $1.name }
            return $0.latestUpdate > $1.latestUpdate
        }
    }

    func open(_ task: CodexTask) {
        guard let url = task.deepLink else {
            errorMessage = "任务链接无效：\(task.id)"
            return
        }
        guard NSWorkspace.shared.open(url) else {
            errorMessage = "无法打开任务，请确认 ChatGPT / Codex 已安装。"
            return
        }
        errorMessage = nil
        readAcknowledgements[task.id] = task.updatedMillis
        tasks = tasks.map { currentTask in
            currentTask.id == task.id && currentTask.updatedMillis == task.updatedMillis
                ? currentTask.replacingUnreadUpdate(with: false)
                : currentTask
        }

        // 从后置窗口触发深链时，LaunchServices 不一定会把已运行的 Codex 提到前台。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let codex = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.openai.codex"
            }) else { return }
            codex.activate(options: [.activateAllWindows])
        }

        // Codex 会在任务被打开后清除未读更新状态；稍后只读刷新，让绿色标识及时同步消失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }
}

struct UsageWindowDisplay: Identifiable, Equatable {
    let label: String
    let remainingPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var id: String { label }
}

struct UsageDailyBucket: Identifiable, Equatable {
    let dateKey: String
    let tokens: Int64

    var id: String { dateKey }
}

struct LocalUsageEstimate: Equatable {
    let mostUsedModel: String?
    let inputPricePerMillionTokens: Double?
}

struct UsageSnapshot: Equatable {
    let windows: [UsageWindowDisplay]
    let planType: String?
    let resetCreditCount: Int?
    let resetCreditExpiresAt: Date?
    let dailyBuckets: [UsageDailyBucket]
    let localEstimate: LocalUsageEstimate
    let refreshedAt: Date
}

enum UsageState: Equatable {
    case loading
    case available(UsageSnapshot)
    case unavailable(String)
}

enum CodexUsageError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case protocolFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "没有找到 Codex 官方程序。请确认 ChatGPT / Codex 已安装。"
        case let .launchFailed(message):
            return "无法启动 Codex 用量服务：\(message)"
        case let .protocolFailed(message):
            return "Codex 用量响应异常：\(message)"
        case .timedOut:
            return "读取 Codex 剩余用量超时。"
        }
    }
}

enum UsageSnapshotParser {
    static func rateLimitDetails(
        from result: [String: Any]
    ) throws -> (windows: [UsageWindowDisplay], resetCreditCount: Int?, resetCreditExpiresAt: Date?) {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw CodexUsageError.protocolFailed("缺少 rateLimits")
        }

        let candidates: [(key: String, fallback: String)] = [
            ("primary", "主要额度"),
            ("secondary", "次要额度"),
        ]
        let windows = candidates.compactMap { candidate -> UsageWindowDisplay? in
            guard let rawWindow = rateLimits[candidate.key] as? [String: Any],
                  let usedNumber = rawWindow["usedPercent"] as? NSNumber else {
                return nil
            }
            let usedPercent = min(max(usedNumber.intValue, 0), 100)
            let duration = (rawWindow["windowDurationMins"] as? NSNumber)?.intValue
            let resetTimestamp = (rawWindow["resetsAt"] as? NSNumber)?.doubleValue
            return UsageWindowDisplay(
                label: durationLabel(minutes: duration, fallback: candidate.fallback),
                remainingPercent: 100 - usedPercent,
                durationMinutes: duration,
                resetsAt: resetTimestamp.flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
            )
        }
        .sorted {
            ($0.durationMinutes ?? Int.max, $0.label)
                < ($1.durationMinutes ?? Int.max, $1.label)
        }

        guard !windows.isEmpty else {
            throw CodexUsageError.protocolFailed("没有可显示的用量周期")
        }

        let resetCredits = result["rateLimitResetCredits"] as? [String: Any]
        let resetCreditCount = (resetCredits?["availableCount"] as? NSNumber)?.intValue
        let creditRows = resetCredits?["credits"] as? [[String: Any]]
        let expirationDates = creditRows?
            .compactMap { ($0["expiresAt"] as? NSNumber)?.doubleValue }
            .filter { $0 > 0 }
            .map { Date(timeIntervalSince1970: $0) } ?? []

        return (windows, resetCreditCount, expirationDates.min())
    }

    static func windows(from result: [String: Any]) throws -> [UsageWindowDisplay] {
        try rateLimitDetails(from: result).windows
    }

    static func planType(from result: [String: Any]) -> String? {
        let account = result["account"] as? [String: Any]
        let rateLimits = result["rateLimits"] as? [String: Any]
        guard let planType = (account?["planType"] as? String)
            ?? (rateLimits?["planType"] as? String) else { return nil }
        let trimmed = planType.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dailyBuckets(from result: [String: Any]) -> [UsageDailyBucket] {
        guard let rawBuckets = result["dailyUsageBuckets"] as? [[String: Any]] else {
            return []
        }
        return rawBuckets.compactMap { bucket in
            guard let dateKey = bucket["startDate"] as? String,
                  dateKey.count == 10,
                  let tokens = bucket["tokens"] as? NSNumber else {
                return nil
            }
            return UsageDailyBucket(dateKey: dateKey, tokens: max(0, tokens.int64Value))
        }
        .sorted { $0.dateKey < $1.dateKey }
    }

    private static func durationLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes == 10_080 { return "每周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}

enum LocalUsageEstimator {
    private struct ModelRow: Decodable {
        let model: String
        let tokens: Int64
    }

    private static let query = """
    SELECT
      trim(model) AS model,
      CAST(SUM(tokens_used) AS INTEGER) AS tokens
    FROM threads
    WHERE archived = 0
      AND trim(COALESCE(model, '')) <> ''
      AND COALESCE(tokens_used, 0) > 0
      AND CAST(COALESCE(NULLIF(updated_at_ms, 0), updated_at * 1000) AS INTEGER)
          >= CAST(strftime('%s', 'now', '-30 days') AS INTEGER) * 1000
    GROUP BY trim(model)
    ORDER BY tokens DESC, model ASC
    LIMIT 1;
    """

    static func load() -> LocalUsageEstimate {
        do {
            let databaseURL = try TaskRepository.currentDatabaseURLForUsageAnalytics()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [
                "-readonly",
                "-json",
                "-cmd", ".timeout 800",
                databaseURL.path,
                query,
            ]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let row = try JSONDecoder().decode([ModelRow].self, from: data).first else {
                return LocalUsageEstimate(mostUsedModel: nil, inputPricePerMillionTokens: nil)
            }
            return LocalUsageEstimate(
                mostUsedModel: row.model,
                inputPricePerMillionTokens: inputPricePerMillionTokens(for: row.model)
            )
        } catch {
            return LocalUsageEstimate(mostUsedModel: nil, inputPricePerMillionTokens: nil)
        }
    }

    private static func inputPricePerMillionTokens(for rawModel: String) -> Double? {
        let model = rawModel.lowercased()
        if model.contains("gpt-5.6-luna") { return 1.0 }
        if model.contains("gpt-5.6-terra") { return 2.5 }
        if model.contains("gpt-5.6-sol") || model == "gpt-5.6" { return 5.0 }
        if model.contains("gpt-5.5-pro") { return 30.0 }
        if model.contains("gpt-5.5") { return 5.0 }
        if model.contains("gpt-5.4-mini") { return 0.75 }
        if model.contains("gpt-5.4-nano") { return 0.20 }
        if model.contains("gpt-5.4-pro") { return 30.0 }
        if model.contains("gpt-5.4") { return 2.5 }
        if model.contains("gpt-5.3-codex") || model.contains("gpt-5.2-codex") { return 1.75 }
        if model.contains("gpt-5-codex") || model == "gpt-5" { return 1.25 }
        if model.contains("gpt-5-mini") { return 0.25 }
        return nil
    }
}

final class CodexUsageClient {
    typealias Completion = (Result<UsageSnapshot, Error>) -> Void

    private enum RequestKind {
        case rateLimits
        case account
        case usage
    }

    private let queue = DispatchQueue(label: "io.github.codexrecenttasks.usage")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var readBuffer = Data()
    private var initialized = false
    private var isStopping = false
    private var nextRequestID = 2
    private var pendingRequests: [Int: RequestKind] = [:]
    private var pendingCompletions: [Completion] = []
    private var rateLimitDetails: (
        windows: [UsageWindowDisplay],
        resetCreditCount: Int?,
        resetCreditExpiresAt: Date?
    )?
    private var planType: String?
    private var dailyBuckets: [UsageDailyBucket] = []

    func refresh(completion: @escaping Completion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCompletions.append(completion)
            if self.process?.isRunning == true {
                if self.initialized {
                    self.sendUsageRequestsIfNeeded()
                }
                return
            }
            self.start()
        }
    }

    func stop() {
        queue.sync {
            shutdown()
            pendingCompletions.removeAll()
        }
    }

    private func start() {
        do {
            let executableURL = try Self.executableURL()
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] terminatedProcess in
                self?.queue.async {
                    guard let self,
                          self.process === terminatedProcess,
                          !self.isStopping else { return }
                    self.failPending(
                        CodexUsageError.launchFailed("进程退出码 \(terminatedProcess.terminationStatus)")
                    )
                    self.resetProcessState()
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async {
                    self?.consume(data)
                }
            }

            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
            readBuffer.removeAll(keepingCapacity: true)
            initialized = false
            isStopping = false
            pendingRequests.removeAll()

            try process.run()
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-recent-tasks-sidebar",
                        "title": "Codex 最近任务栏",
                        "version": appVersion,
                    ],
                ],
            ])
            scheduleTimeout(for: 1)
        } catch {
            failPending(error)
            shutdown()
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }

        if id == 1, !initialized {
            guard object["error"] == nil else {
                failPending(CodexUsageError.protocolFailed("初始化失败"))
                shutdown()
                return
            }
            initialized = true
            send(["method": "initialized"])
            sendUsageRequestsIfNeeded()
            return
        }

        guard let requestKind = pendingRequests.removeValue(forKey: id) else { return }
        if object["error"] == nil,
           let result = object["result"] as? [String: Any] {
            switch requestKind {
            case .rateLimits:
                do {
                    rateLimitDetails = try UsageSnapshotParser.rateLimitDetails(from: result)
                    planType = UsageSnapshotParser.planType(from: result) ?? planType
                } catch {
                    failPending(error)
                    shutdown()
                    return
                }
            case .account:
                planType = UsageSnapshotParser.planType(from: result) ?? planType
            case .usage:
                dailyBuckets = UsageSnapshotParser.dailyBuckets(from: result)
            }
        } else if requestKind == .rateLimits {
            failPending(CodexUsageError.protocolFailed("读取限额请求失败"))
            shutdown()
            return
        }

        finishUsageRequestsIfReady()
    }

    private func sendUsageRequestsIfNeeded() {
        guard initialized, pendingRequests.isEmpty, !pendingCompletions.isEmpty else { return }
        rateLimitDetails = nil
        planType = nil
        dailyBuckets = []

        sendRequest(kind: .rateLimits, method: "account/rateLimits/read", params: NSNull())
        sendRequest(kind: .account, method: "account/read", params: ["refreshToken": false])
        sendRequest(kind: .usage, method: "account/usage/read", params: NSNull())
    }

    private func sendRequest(kind: RequestKind, method: String, params: Any) {
        let requestID = nextRequestID
        nextRequestID += 1
        pendingRequests[requestID] = kind
        send([
            "id": requestID,
            "method": method,
            "params": params,
        ])
        scheduleTimeout(for: requestID)
    }

    private func finishUsageRequestsIfReady() {
        guard pendingRequests.isEmpty else { return }
        guard let rateLimitDetails else {
            failPending(CodexUsageError.protocolFailed("缺少限额结果"))
            return
        }
        let snapshot = UsageSnapshot(
            windows: rateLimitDetails.windows,
            planType: planType,
            resetCreditCount: rateLimitDetails.resetCreditCount,
            resetCreditExpiresAt: rateLimitDetails.resetCreditExpiresAt,
            dailyBuckets: dailyBuckets,
            localEstimate: LocalUsageEstimator.load(),
            refreshedAt: Date()
        )
        completePending(with: .success(snapshot))
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            failPending(CodexUsageError.protocolFailed("无法编码请求"))
            shutdown()
            return
        }
        data.append(0x0A)
        inputHandle?.write(data)
    }

    private func scheduleTimeout(for requestID: Int) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            if requestID == 1 {
                guard !self.initialized else { return }
                self.failPending(CodexUsageError.timedOut)
                self.shutdown()
                return
            }
            guard let requestKind = self.pendingRequests.removeValue(forKey: requestID) else { return }
            if requestKind == .rateLimits {
                self.failPending(CodexUsageError.timedOut)
                self.shutdown()
            } else {
                self.finishUsageRequestsIfReady()
            }
        }
    }

    private func completePending(with result: Result<UsageSnapshot, Error>) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    private func failPending(_ error: Error) {
        completePending(with: .failure(error))
    }

    private func shutdown() {
        isStopping = true
        outputHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        resetProcessState()
        isStopping = false
    }

    private func resetProcessState() {
        outputHandle?.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        readBuffer.removeAll(keepingCapacity: false)
        initialized = false
        pendingRequests.removeAll()
        rateLimitDetails = nil
        planType = nil
        dailyBuckets = []
    }

    private static func executableURL() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CODEX_APP_SERVER_OVERRIDE"], !override.isEmpty {
            guard fileManager.isExecutableFile(atPath: override) else {
                throw CodexUsageError.executableNotFound
            }
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw CodexUsageError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .loading

    typealias RefreshCompletion = () -> Void

    private let client = CodexUsageClient()
    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        client.stop()
    }

    func refresh(completion: RefreshCompletion? = nil) {
        client.refresh { [weak self] result in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self else { return }
                switch result {
                case let .success(snapshot):
                    self.state = .available(snapshot)
                case let .failure(error):
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        client.stop()
    }
}

struct RecentTaskRowView: View {
    let projectName: String
    let task: CodexTask
    let now: Date
    let openTask: () -> Void

    @State private var isHovering = false

    var body: some View {
        let shortTime = TimeLabelFormatter.shortLabel(milliseconds: task.updatedMillis, now: now)
        let displayState = task.displayState
        Button(action: openTask) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, height: 18)

                Text(task.title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if let badgeText = displayState.badgeText {
                    HStack(spacing: 5) {
                        Text(shortTime)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        HStack(spacing: 3) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7.5, weight: .semibold))
                            Text(badgeText)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(displayState.tintColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(displayState.tintColor.opacity(0.12), in: Capsule())
                    }
                    .fixedSize()
                } else {
                    Text(shortTime)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                ProjectActions.copyPath(task.canonicalProjectPath)
            } label: {
                Label("复制项目路径", systemImage: "doc.on.doc")
            }

            Button {
                ProjectActions.revealInFinder(task.canonicalProjectPath)
            } label: {
                Label("在 Finder 打开项目", systemImage: "folder")
            }

            Button {
                ProjectActions.openInTerminal(task.canonicalProjectPath)
            } label: {
                Label("在终端打开项目", systemImage: "terminal")
            }
        }
        .onHover { isHovering = $0 }
        .help("\(projectName)\n任务：\(task.title)\n状态：\(displayState.statusDescription)\n最近活动：\(TimeLabelFormatter.fullLabel(milliseconds: task.updatedMillis))\nThread ID：\(task.id)")
        .accessibilityLabel("\(projectName)，任务 \(task.title)，\(displayState.statusDescription)，最近活动 \(shortTime)")
        .accessibilityHint("打开这条 Codex 任务")
    }
}

struct FolderTaskSectionView: View {
    let group: TaskGroup
    let now: Date
    let openTask: (CodexTask) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .frame(width: 17)

                Text(group.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.tasks.count) 条")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("文件夹 \(group.name)，最近 48 小时 \(group.tasks.count) 条任务")

            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 {
                    Divider()
                        .padding(.leading, 35)
                        .opacity(0.45)
                }
                RecentTaskRowView(projectName: group.name, task: task, now: now) {
                    openTask(task)
                }
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var windowMode: WindowModeModel
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var refreshRotation = 0.0
    @State private var isUsageAnalyticsExpanded = false

    private var groups: [TaskGroup] {
        store.groups(matching: searchText)
    }

    private var visibleTaskCount: Int {
        groups.reduce(0) { $0 + $1.tasks.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField

            Divider()
                .opacity(0.5)

            content

            Divider()
                .opacity(0.5)

            footer
        }
        .frame(minWidth: 300, idealWidth: 360, minHeight: 420, idealHeight: 720)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex 最近任务")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(groups.count) 个文件夹 · \(visibleTaskCount) 个任务 · 最近 48 小时")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(refreshRotation))
                        .opacity(isRefreshing ? 0.75 : 1)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.06), in: Circle())
                .disabled(isRefreshing)
                .help("立即刷新任务与剩余用量")
                .accessibilityLabel("立即刷新任务与剩余用量")
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        if windowMode.mode == .pinned {
                            windowMode.dragPinnedWindow(translation: value.translation, ended: false)
                        }
                    }
                    .onEnded { value in
                        if windowMode.mode == .pinned {
                            windowMode.dragPinnedWindow(translation: value.translation, ended: true)
                        } else if abs(value.translation.width) >= 44,
                                  abs(value.translation.width) > abs(value.translation.height) {
                            windowMode.selectDockSide(value.translation.width < 0 ? .left : .right)
                        }
                    }
            )
            .help(windowMode.mode == .docked ? "拖动标题区域向左或向右切换吸附位置" : "拖动窗口可自由移动")

            usageSummary
            usageResetSummary
            usageAnalyticsDisclosure

            if isUsageAnalyticsExpanded {
                usageAnalyticsPanel
            }

            HStack(spacing: 8) {
                windowModeSelector
                    .frame(maxWidth: .infinity)

                Group {
                    if windowMode.mode == .docked {
                        dockSideSelector
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
            refreshRotation += 360
        }

        let startedAt = Date()
        var remainingRefreshes = 2
        let markFinished = {
            remainingRefreshes -= 1
            guard remainingRefreshes == 0 else { return }

            let elapsed = Date().timeIntervalSince(startedAt)
            let delay = max(0.0, 0.45 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.18)) {
                    isRefreshing = false
                    refreshRotation = 0
                }
            }
        }

        store.refresh(completion: markFinished)
        usageStore.refresh(completion: markFinished)
    }

    private var usageSummary: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(usageTint)

            switch usageStore.state {
            case .loading:
                Text("正在读取剩余用量…")
                    .foregroundStyle(.secondary)
            case let .available(snapshot):
                Text("剩余用量")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(snapshot.windows) { window in
                    HStack(spacing: 3) {
                        Text(window.label)
                            .foregroundStyle(.secondary)
                        Text("\(window.remainingPercent)%")
                            .fontWeight(.semibold)
                            .foregroundStyle(usageColor(for: window.remainingPercent))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
            case .unavailable:
                Text("用量暂时不可用")
                    .foregroundStyle(.secondary)
            }

            if case .loading = usageStore.state {
                Spacer()
            } else if case .unavailable = usageStore.state {
                Spacer()
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(usageHelpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(usageAccessibilityLabel)
        .animation(nil, value: isUsageAnalyticsExpanded)
    }

    private var usageTint: Color {
        switch usageStore.state {
        case .loading:
            return .secondary
        case let .available(snapshot):
            return snapshot.windows.map(\.remainingPercent).min().map(usageColor(for:)) ?? .secondary
        case .unavailable:
            return .orange
        }
    }

    @ViewBuilder
    private var usageResetSummary: some View {
        if case let .available(snapshot) = usageStore.state {
            let resetWindows = snapshot.windows.filter { $0.resetsAt != nil }
            if !resetWindows.isEmpty {
                VStack(spacing: 5) {
                    ForEach(resetWindows) { window in
                        if let resetsAt = window.resetsAt {
                            HStack(spacing: 7) {
                                Image(systemName: window.durationMinutes == 10_080
                                    ? "calendar.badge.clock"
                                    : "clock")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(usageTint)

                                Text("\(window.label)额度")
                                    .foregroundStyle(.secondary)

                                Spacer(minLength: 4)

                                Text(relativeResetText(resetsAt, now: store.now))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.88)
                            }
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(
                                Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .animation(nil, value: isUsageAnalyticsExpanded)
            }
        }
    }

    private func usageColor(for remainingPercent: Int) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 30 { return .orange }
        return .accentColor
    }

    private var usageHelpText: String {
        switch usageStore.state {
        case .loading:
            return "正在通过 Codex 官方服务读取剩余用量"
        case .available:
            return "剩余用量和额度重置时间每 60 秒刷新。"
        case let .unavailable(message):
            return message
        }
    }

    private var usageAccessibilityLabel: String {
        switch usageStore.state {
        case .loading:
            return "正在读取剩余用量"
        case let .available(snapshot):
            let details = snapshot.windows.map { window in
                var detail = "\(window.label)剩余\(window.remainingPercent)%"
                if let resetsAt = window.resetsAt {
                    detail += "，\(relativeResetText(resetsAt, now: store.now))"
                }
                return detail
            }.joined(separator: "，")
            return "剩余用量，\(details)"
        case .unavailable:
            return "用量暂时不可用"
        }
    }

    private var usageAnalyticsDisclosure: some View {
        Button {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isUsageAnalyticsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("用量统计")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if case let .available(snapshot) = usageStore.state {
                    Text(accountSummary(snapshot))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isUsageAnalyticsExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isUsageAnalyticsExpanded ? "收起用量统计" : "展开用量统计")
    }

    @ViewBuilder
    private var usageAnalyticsPanel: some View {
        switch usageStore.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取统计数据…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 44)
        case let .unavailable(message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("统计数据暂时不可用")
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
            }
            .frame(height: 44)
            .help(message)
        case let .available(snapshot):
            VStack(spacing: 9) {
                resetCreditRow(snapshot)

                Divider()
                    .opacity(0.45)

                HStack(spacing: 0) {
                    analyticsMetric(
                        title: "\(latestDailyUsage(in: snapshot).label) token",
                        value: compactTokenCount(latestDailyUsage(in: snapshot).tokens)
                    )
                    Divider()
                    analyticsMetric(
                        title: "近 30 天 token",
                        value: compactTokenCount(last30DayTokens(in: snapshot))
                    )
                }
                .frame(height: 42)

                HStack(spacing: 0) {
                    analyticsMetric(
                        title: "\(latestDailyUsage(in: snapshot).label)等效 API 成本",
                        value: estimatedCostText(tokens: latestDailyUsage(in: snapshot).tokens, snapshot: snapshot)
                    )
                    Divider()
                    analyticsMetric(
                        title: "近 30 天等效 API 成本",
                        value: estimatedCostText(tokens: last30DayTokens(in: snapshot), snapshot: snapshot)
                    )
                }
                .frame(height: 42)

                Divider()
                    .opacity(0.45)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("近 30 天 token 趋势")
                        Spacer()
                        Text("峰值 \(compactTokenCount(chartBuckets(snapshot).map(\.tokens).max() ?? 0))")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)

                    usageBarChart(chartBuckets(snapshot))
                        .frame(height: 52)
                }

                Divider()
                    .opacity(0.45)

                HStack {
                    Text("最常用模型")
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    Text(snapshot.localEstimate.mostUsedModel ?? "暂无数据")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }

                Text(analyticsFootnote(snapshot))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(
                Color.primary.opacity(0.028),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
    }

    private func resetCreditRow(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text("限额重置额度")
                    .font(.system(size: 10.5, weight: .medium))
                Text(resetCreditCountText(snapshot.resetCreditCount))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            Spacer()
            if let expiration = snapshot.resetCreditExpiresAt {
                Label(relativeExpirationText(expiration), systemImage: "clock")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("有效期未提供")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func analyticsMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
    }

    private func usageBarChart(_ buckets: [UsageDailyBucket]) -> some View {
        GeometryReader { geometry in
            let peak = max(1, buckets.map(\.tokens).max() ?? 1)
            let peakIndex = buckets.firstIndex(where: { $0.tokens == peak })
            let count = max(1, buckets.count)
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(0, count - 1))
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    let ratio = Double(bucket.tokens) / Double(peak)
                    RoundedRectangle(cornerRadius: min(2, barWidth / 2), style: .continuous)
                        .fill(chartColor(index: index, isPeak: index == peakIndex && bucket.tokens > 0))
                        .frame(
                            width: barWidth,
                            height: max(bucket.tokens > 0 ? 3 : 1, geometry.size.height * ratio)
                        )
                        .accessibilityLabel("\(bucket.dateKey)，\(compactTokenCount(bucket.tokens)) token")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func chartColor(index: Int, isPeak: Bool) -> Color {
        if isPeak {
            return Color(nsColor: .systemOrange)
        }
        switch index % 3 {
        case 0:
            return Color(nsColor: .systemBlue).opacity(0.82)
        case 1:
            return Color(nsColor: .systemCyan).opacity(0.88)
        default:
            return Color(nsColor: .systemIndigo).opacity(0.78)
        }
    }

    private func accountSummary(_ snapshot: UsageSnapshot) -> String {
        let plan = displayPlanType(snapshot.planType) ?? "Codex"
        let elapsed = max(0, Date().timeIntervalSince(snapshot.refreshedAt))
        return elapsed < 60 ? "\(plan) · 刚刚更新" : "\(plan) · \(Int(elapsed / 60)) 分钟前"
    }

    private func displayPlanType(_ rawPlan: String?) -> String? {
        guard let rawPlan else { return nil }
        let normalized = rawPlan.lowercased()
        if normalized == "promax" || normalized == "pro_max" || normalized == "pro-max" {
            return "Pro Max"
        }
        if normalized == "prolite" || normalized == "pro_lite" || normalized == "pro-lite" {
            return "Pro Lite"
        }
        if normalized.contains("plus") {
            return "Plus"
        }
        if normalized.contains("pro") {
            return "Pro"
        }
        return rawPlan.prefix(1).uppercased() + rawPlan.dropFirst()
    }

    private func relativeResetText(_ date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        if remaining == 0 { return "即将重置" }

        let totalMinutes = max(1, remaining / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小时后重置" : "\(days) 天后重置"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分后重置" : "\(hours) 小时后重置"
        }
        return "\(minutes) 分钟后重置"
    }

    private func resetCreditCountText(_ count: Int?) -> String {
        guard let count else { return "暂未提供" }
        return count > 0 ? "\(count) 次可用" : "暂无可用"
    }

    private func relativeExpirationText(_ date: Date) -> String {
        let interval = max(0, date.timeIntervalSinceNow)
        let totalHours = Int(interval / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 { return "\(days) 天 \(hours) 小时后到期" }
        if totalHours > 0 { return "\(totalHours) 小时后到期" }
        return "即将到期"
    }

    private func latestDailyUsage(in snapshot: UsageSnapshot) -> (label: String, tokens: Int64, dateKey: String?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: Date())
        if let today = snapshot.dailyBuckets.first(where: { $0.dateKey == todayKey }) {
            return ("今日", today.tokens, today.dateKey)
        }

        guard let latest = snapshot.dailyBuckets.max(by: { $0.dateKey < $1.dateKey }) else {
            return ("今日", 0, nil)
        }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
           latest.dateKey == formatter.string(from: yesterday) {
            return ("昨日", latest.tokens, latest.dateKey)
        }
        return ("\(String(latest.dateKey.suffix(5)))", latest.tokens, latest.dateKey)
    }

    private func last30DayTokens(in snapshot: UsageSnapshot) -> Int64 {
        chartBuckets(snapshot).reduce(0) { $0 + $1.tokens }
    }

    private func chartBuckets(_ snapshot: UsageSnapshot) -> [UsageDailyBucket] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let tokenByDate = snapshot.dailyBuckets.reduce(into: [String: Int64]()) { result, bucket in
            result[bucket.dateKey, default: 0] += bucket.tokens
        }
        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 29, to: Date()) else { return nil }
            let dateKey = formatter.string(from: date)
            return UsageDailyBucket(dateKey: dateKey, tokens: tokenByDate[dateKey] ?? 0)
        }
    }

    private func compactTokenCount(_ tokens: Int64) -> String {
        let value = Double(tokens)
        if tokens >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return "\(tokens)"
    }

    private func estimatedCostText(tokens: Int64, snapshot: UsageSnapshot) -> String {
        guard let rate = snapshot.localEstimate.inputPricePerMillionTokens else {
            return "—"
        }
        return String(format: "$%.2f", Double(tokens) / 1_000_000 * rate)
    }

    private func analyticsFootnote(_ snapshot: UsageSnapshot) -> String {
        let dailyUsage = latestDailyUsage(in: snapshot)
        let estimateNote = "费用按最常用模型的官方输入价估算，不代表实际账单"
        guard dailyUsage.label != "今日", let dateKey = dailyUsage.dateKey else {
            return estimateNote
        }
        return "官方每日数据截至 \(String(dateKey.suffix(5)))；\(estimateNote)"
    }

    private var windowModeSelector: some View {
        HStack(spacing: 0) {
            windowModeSegment(title: "吸附", icon: "rectangle.leadinghalf.inset.filled", mode: .docked)
            selectorDivider
            windowModeSegment(title: "置顶", icon: "pin.fill", mode: .pinned)
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(selectorBorder)
    }

    private var dockSideSelector: some View {
        HStack(spacing: 0) {
            dockSideSegment(title: "左侧", icon: "rectangle.lefthalf.inset.filled", side: .left)
            selectorDivider
            dockSideSegment(title: "右侧", icon: "rectangle.righthalf.inset.filled", side: .right)
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(selectorBorder)
    }

    private var selectorDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 16)
    }

    private var selectorBorder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }

    private func windowModeSegment(title: String, icon: String, mode: WindowDisplayMode) -> some View {
        let isSelected = windowMode.mode == mode
        return Button {
            windowMode.select(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .docked ? "吸附 Codex" : "单独置顶")
    }

    private func dockSideSegment(title: String, icon: String, side: DockSide) -> some View {
        let isSelected = windowMode.dockSide == side
        return Button {
            windowMode.selectDockSide(side)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("吸附到 Codex \(title)")
        .help("立即吸附到 Codex \(title)，也可以直接拖动窗口切换")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("搜索任务或项目", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text("暂时无法读取任务")
                    .font(.headline)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重新读取") {
                    store.refresh()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 25))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? "最近 48 小时没有任务" : "最近 48 小时没有匹配的任务")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        FolderTaskSectionView(group: group, now: store.now) { task in
                            store.open(task)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.errorMessage == nil ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(windowMode.statusText)
            Spacer()
            Text("任务 30 秒 · 用量 60 秒")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .help(store.databasePath)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TaskStore()
    private let usageStore = UsageStore()
    private let windowMode = WindowModeModel()
    private var panel: NSWindow?
    private var statusItem: NSStatusItem?
    private var dockTimer: Timer?
    private var isApplyingDockPosition = false
    private var isMiniaturizedBecauseCodexWindowMissing = false
    private var lastCodexFrameSample: (frame: NSRect, date: Date)?
    private var pinnedDragStartOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        windowMode.onModeChange = { [weak self] mode in
            self?.applyWindowMode(mode)
        }
        windowMode.onDockSideChange = { [weak self] _ in
            self?.dockToCodexWindow()
        }
        windowMode.onPinnedDrag = { [weak self] translation, ended in
            self?.movePinnedWindow(translation: translation, ended: ended)
        }
        createPanel()
        createStatusItem()

        guard CodexWindowLocator.isCodexRunning() else {
            terminateBecauseCodexExited()
            return
        }

        applyWindowMode(.docked)
        if CodexWindowLocator.largestWindowFrame() != nil {
            showPanel()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPanel()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        usageStore.stop()
    }

    private func createPanel() {
        let widthPreset = WindowWidthPreset.saved
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(widthPreset.rawValue), height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex 最近任务"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 420)
        panel.maxSize = NSSize(width: 560, height: 1200)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.setFrameAutosaveName("CodexRecentTasksPanelFrame")
        panel.contentView = NSHostingView(
            rootView: TaskListView(store: store, usageStore: usageStore, windowMode: windowMode)
        )

        if !panel.setFrameUsingName("CodexRecentTasksPanelFrame"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 12, y: visible.maxY - 12))
        }

        self.panel = panel
        applyWindowWidthPreset(widthPreset, persist: false)
    }

    private func applyWindowMode(_ mode: WindowDisplayMode) {
        guard let panel else { return }
        dockTimer?.invalidate()
        dockTimer = nil
        pinnedDragStartOrigin = nil

        switch mode {
        case .docked:
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            dockToCodexWindow()
            let timer = Timer(timeInterval: DockPlacement.trackingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.dockToCodexWindow()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            dockTimer = timer
        case .pinned:
            isMiniaturizedBecauseCodexWindowMissing = false
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.level = .statusBar
            recordWindowLayerState("pinned")
            updateWindowStatus("单独置顶 · 点击任务跳转 Codex")
            panel.orderFrontRegardless()
        }
    }

    private func dockToCodexWindow() {
        guard let panel else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            updateDockSideFromCurrentPosition()
            return
        }
        if CodexWindowLocator.isCodexMiniaturized() {
            lastCodexFrameSample = nil
            miniaturizePanelUntilCodexWindowReturns()
            updateWindowStatus("Codex 已最小化")
            return
        }
        guard let codexFrame = CodexWindowLocator.largestWindowFrame() else {
            if CodexWindowLocator.isCodexRunning() {
                lastCodexFrameSample = nil
                miniaturizePanelUntilCodexWindowReturns()
                updateWindowStatus("Codex 已最小化")
            } else {
                terminateBecauseCodexExited()
            }
            return
        }
        if shouldTreatAsCodexMiniaturizing(codexFrame) {
            miniaturizePanelUntilCodexWindowReturns()
            updateWindowStatus("Codex 正在最小化")
            return
        }

        let screen = DockPlacement.dockingScreen(for: codexFrame, screens: NSScreen.screens) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            updateWindowStatus("无法确定屏幕位置")
            return
        }

        let targetPanelSize = DockPlacement.targetPanelSize(
            codexFrame: codexFrame,
            currentPanelSize: panel.frame.size,
            minPanelSize: panel.minSize,
            maxPanelSize: panel.maxSize,
            visibleFrame: visibleFrame
        )
        let targetOrigin = DockPlacement.targetOrigin(
            codexFrame: codexFrame,
            panelSize: targetPanelSize,
            visibleFrame: visibleFrame,
            side: windowMode.dockSide
        )

        if abs(panel.frame.origin.x - targetOrigin.x) > DockPlacement.movementTolerance ||
            abs(panel.frame.origin.y - targetOrigin.y) > DockPlacement.movementTolerance ||
            abs(panel.frame.size.width - targetPanelSize.width) > DockPlacement.sizeTolerance ||
            abs(panel.frame.size.height - targetPanelSize.height) > DockPlacement.sizeTolerance {
            isApplyingDockPosition = true
            panel.setFrame(NSRect(origin: targetOrigin, size: targetPanelSize), display: true)
            isApplyingDockPosition = false
        }
        restorePanelAfterCodexWindowReturns()
        updateDockedWindowLevel()
    }

    private func shouldTreatAsCodexMiniaturizing(_ codexFrame: NSRect) -> Bool {
        defer {
            lastCodexFrameSample = (codexFrame, Date())
        }
        guard let lastCodexFrameSample else { return false }

        let elapsed = Date().timeIntervalSince(lastCodexFrameSample.date)
        guard elapsed <= DockPlacement.rapidShrinkInterval else { return false }

        let previousArea = lastCodexFrameSample.frame.area
        let currentArea = codexFrame.area
        guard previousArea > 0, currentArea > 0 else { return false }
        let widthShrank = codexFrame.width < lastCodexFrameSample.frame.width - DockPlacement.rapidShrinkDimensionDelta
        let heightShrank = codexFrame.height < lastCodexFrameSample.frame.height - DockPlacement.rapidShrinkDimensionDelta
        return widthShrank || heightShrank || currentArea < previousArea * DockPlacement.rapidShrinkAreaRatio
    }

    private func miniaturizePanelUntilCodexWindowReturns() {
        guard windowMode.mode == .docked, let panel, !isMiniaturizedBecauseCodexWindowMissing else { return }
        isMiniaturizedBecauseCodexWindowMissing = true
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.level = .normal
        panel.orderOut(nil)
    }

    private func restorePanelAfterCodexWindowReturns() {
        guard windowMode.mode == .docked, let panel, isMiniaturizedBecauseCodexWindowMissing else { return }
        isMiniaturizedBecauseCodexWindowMissing = false
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        guard
            windowMode.mode == .docked,
            !isApplyingDockPosition,
            let movedPanel = notification.object as? NSWindow,
            movedPanel === panel
        else {
            return
        }
        updateDockSideFromCurrentPosition()
    }

    private func updateDockSideFromCurrentPosition() {
        guard let panel, let codexFrame = CodexWindowLocator.largestWindowFrame() else { return }
        let newSide: DockSide = panel.frame.midX < codexFrame.midX ? .left : .right
        windowMode.observeDockSide(newSide)
        updateWindowStatus("正在切换到 Codex \(newSide.label)")
    }

    private func movePinnedWindow(translation: CGSize, ended: Bool) {
        guard windowMode.mode == .pinned, let panel else { return }
        if pinnedDragStartOrigin == nil {
            pinnedDragStartOrigin = panel.frame.origin
        }
        guard let startOrigin = pinnedDragStartOrigin else { return }

        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let proposedOrigin = NSPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y - translation.height
        )
        let targetOrigin: NSPoint
        if let visibleFrame {
            targetOrigin = NSPoint(
                x: min(max(visibleFrame.minX, proposedOrigin.x), visibleFrame.maxX - panel.frame.width),
                y: min(max(visibleFrame.minY, proposedOrigin.y), visibleFrame.maxY - panel.frame.height)
            )
        } else {
            targetOrigin = proposedOrigin
        }
        panel.setFrameOrigin(targetOrigin)

        if ended {
            panel.saveFrame(usingName: "CodexRecentTasksPanelFrame")
            pinnedDragStartOrigin = nil
        }
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        updateDockedWindowLevel()
    }

    @objc private func workspaceApplicationDidTerminate(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == "com.openai.codex"
        else {
            return
        }
        terminateBecauseCodexExited()
    }

    private func terminateBecauseCodexExited() {
        updateWindowStatus("Codex 已退出")
        NSApp.terminate(nil)
    }

    private func updateDockedWindowLevel() {
        guard windowMode.mode == .docked, let panel else { return }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let shouldBeFront = frontmostBundleID == "com.openai.codex" || frontmostBundleID == ownBundleID

        guard !isMiniaturizedBecauseCodexWindowMissing else {
            recordWindowLayerState("miniaturized", frontmostBundleID: frontmostBundleID)
            return
        }

        if shouldBeFront {
            if panel.level != .floating {
                panel.level = .floating
                panel.orderFrontRegardless()
            }
        } else if panel.level != .normal {
            panel.level = .normal
            panel.orderBack(nil)
        }

        let foregroundState: String
        if frontmostBundleID == "com.openai.codex" {
            foregroundState = "跟随 Codex 前置"
        } else if frontmostBundleID == ownBundleID {
            foregroundState = "正在操作"
        } else {
            foregroundState = "已随 Codex 后置"
        }
        recordWindowLayerState(shouldBeFront ? "front" : "back", frontmostBundleID: frontmostBundleID)
        updateWindowStatus("已吸附 \(windowMode.dockSide.label) · \(foregroundState)")
    }

    private func recordWindowLayerState(_ state: String, frontmostBundleID: String? = nil) {
        UserDefaults.standard.set(state, forKey: "CodexRecentTasksWindowLayerState")
        UserDefaults.standard.set(panel?.level.rawValue ?? -1, forKey: "CodexRecentTasksWindowLevel")
        UserDefaults.standard.set(
            frontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            forKey: "CodexRecentTasksFrontmostBundleID"
        )
    }

    private func updateWindowStatus(_ text: String) {
        if windowMode.statusText != text {
            windowMode.statusText = text
        }
    }

    private func applyWindowWidthPreset(_ preset: WindowWidthPreset, persist: Bool = true) {
        guard let panel else { return }
        if persist {
            preset.save()
        }

        var frame = panel.frame
        let width = min(max(CGFloat(preset.rawValue), panel.minSize.width), panel.maxSize.width)
        frame.size.width = width
        panel.setFrame(frame, display: true)
        if windowMode.mode == .docked {
            dockToCodexWindow()
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Codex 最近任务")
            button.toolTip = "Codex 最近任务"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示任务栏", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "刷新任务与用量", action: #selector(refreshTasks), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccessibilityPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "复制诊断日志路径", action: #selector(copyDiagnosticLogPath), keyEquivalent: ""))
        menu.addItem(.separator())

        let widthMenu = NSMenu()
        for preset in WindowWidthPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectWindowWidthPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.state = preset == WindowWidthPreset.saved ? .on : .off
            widthMenu.addItem(item)
        }
        let widthItem = NSMenuItem(title: "窗口宽度", action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        guard let panel else { return }
        store.refresh()
        usageStore.refresh()
        if windowMode.mode == .docked {
            dockToCodexWindow()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestAccessibilityPermission() {
        CodexWindowLocator.requestAccessibilityPermission()
    }

    @objc private func copyDiagnosticLogPath() {
        DiagnosticLogger.copyLogPath()
    }

    @objc private func selectWindowWidthPreset(_ sender: NSMenuItem) {
        guard let preset = WindowWidthPreset(rawValue: sender.tag) else { return }
        applyWindowWidthPreset(preset)
        sender.menu?.items.forEach { item in
            item.state = item.tag == preset.rawValue ? .on : .off
        }
    }

    @objc private func refreshTasks() {
        store.refresh()
        usageStore.refresh()
        panel?.orderFrontRegardless()
    }

    @objc private func quit() {
        dockTimer?.invalidate()
        NSApp.terminate(nil)
    }
}

enum SelfTest {
    static func run() -> Int32 {
        do {
            let result = try TaskRepository.loadTasks()
            let tasks = result.tasks
            let uniqueIDs = Set(tasks.map(\CodexTask.id))
            guard uniqueIDs.count == tasks.count else {
                fputs("SELF_TEST_FAILED duplicate thread IDs\n", stderr)
                return 2
            }
            var titleOverrideStatus = ""
            if let expectedTitle = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_TITLE"] {
                guard tasks.contains(where: { $0.title == expectedTitle }) else {
                    fputs("SELF_TEST_FAILED title override\n", stderr)
                    return 7
                }
                titleOverrideStatus = " title_override=ok"
            }
            var unreadOverrideStatus = ""
            if let expectedUnreadID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_UNREAD_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedUnreadID && $0.hasUnreadUpdate
                }) else {
                    fputs("SELF_TEST_FAILED unread override\n", stderr)
                    return 10
                }
                unreadOverrideStatus = " unread_override=ok"
            }
            var readOverrideStatus = ""
            if let expectedReadID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_READ_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedReadID && !$0.hasUnreadUpdate
                }) else {
                    fputs("SELF_TEST_FAILED read override\n", stderr)
                    return 12
                }
                readOverrideStatus = " read_override=ok"
            }
            var runtimeOverrideStatus = ""
            if let expectedRunningID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_RUNNING_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedRunningID
                        && $0.runtimeState == .running
                        && $0.displayState == .running
                }) else {
                    fputs("SELF_TEST_FAILED runtime override\n", stderr)
                    return 13
                }
                runtimeOverrideStatus = " runtime_override=ok"
            }
            var actionOverrideStatus = ""
            if let expectedActionID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_ACTION_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedActionID
                        && $0.runtimeState == .needsAction
                        && $0.displayState == .needsAction
                }) else {
                    fputs("SELF_TEST_FAILED action override\n", stderr)
                    return 14
                }
                actionOverrideStatus = " action_override=ok"
            }
            guard tasks.allSatisfy({ !$0.id.isEmpty && !$0.cwd.isEmpty && $0.updatedMillis > 0 && $0.deepLink != nil }) else {
                fputs("SELF_TEST_FAILED invalid task fields\n", stderr)
                return 3
            }
            for pair in zip(tasks, tasks.dropFirst()) where pair.0.updatedMillis < pair.1.updatedMillis {
                fputs("SELF_TEST_FAILED sort order\n", stderr)
                return 4
            }

            let referenceNow = Date(timeIntervalSince1970: 2_000_000_000)
            let boundaryTask = CodexTask(
                id: "boundary",
                title: "boundary",
                cwd: "/tmp",
                gitBranch: "",
                updatedMillis: Int64(referenceNow.timeIntervalSince1970 * 1000) - RecentTaskPolicy.windowMillis
            )
            let staleTask = CodexTask(
                id: "stale",
                title: "stale",
                cwd: "/tmp",
                gitBranch: "",
                updatedMillis: boundaryTask.updatedMillis - 1
            )
            guard RecentTaskPolicy.includes(boundaryTask, now: referenceNow),
                  !RecentTaskPolicy.includes(staleTask, now: referenceNow) else {
                fputs("SELF_TEST_FAILED recent window boundary\n", stderr)
                return 5
            }

            let visibleFrame = NSRect(x: 0, y: 0, width: 1800, height: 1000)
            let codexFrame = NSRect(x: 400, y: 100, width: 1000, height: 800)
            let panelSize = NSSize(width: 320, height: 680)
            let leftOrigin = DockPlacement.targetOrigin(
                codexFrame: codexFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .left
            )
            let rightOrigin = DockPlacement.targetOrigin(
                codexFrame: codexFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .right
            )
            guard leftOrigin.x < codexFrame.minX,
                  rightOrigin.x > codexFrame.maxX,
                  leftOrigin.y == rightOrigin.y else {
                fputs("SELF_TEST_FAILED dock side placement\n", stderr)
                return 6
            }
            let crampedLeftFrame = NSRect(x: 120, y: 100, width: 900, height: 800)
            let crampedLeftOrigin = DockPlacement.targetOrigin(
                codexFrame: crampedLeftFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .left
            )
            guard crampedLeftOrigin.x >= crampedLeftFrame.maxX else {
                fputs("SELF_TEST_FAILED dock side fallback overlaps app\n", stderr)
                return 6
            }
            let offscreenLeftFrame = NSRect(x: 0, y: 100, width: 900, height: 800)
            let offscreenLeftOrigin = DockPlacement.targetOrigin(
                codexFrame: offscreenLeftFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .left
            )
            guard offscreenLeftOrigin.x >= offscreenLeftFrame.maxX,
                  offscreenLeftOrigin.x >= visibleFrame.minX else {
                fputs("SELF_TEST_FAILED dock side fallback crosses screen\n", stderr)
                return 6
            }

            let usageFixture: [String: Any] = [
                "rateLimits": [
                    "planType": "plus",
                    "primary": [
                        "usedPercent": 35,
                        "windowDurationMins": 300,
                        "resetsAt": 4_102_444_800,
                    ],
                    "secondary": [
                        "usedPercent": 90,
                        "windowDurationMins": 10_080,
                        "resetsAt": 4_102_704_000,
                    ],
                ],
            ]
            let usageWindows = try UsageSnapshotParser.windows(from: usageFixture)
            guard usageWindows == [
                UsageWindowDisplay(
                    label: "5 小时",
                    remainingPercent: 65,
                    durationMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 4_102_444_800)
                ),
                UsageWindowDisplay(
                    label: "每周",
                    remainingPercent: 10,
                    durationMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 4_102_704_000)
                ),
            ] else {
                fputs("SELF_TEST_FAILED usage parsing\n", stderr)
                return 8
            }
            guard UsageSnapshotParser.planType(from: usageFixture) == "plus" else {
                fputs("SELF_TEST_FAILED usage plan parsing\n", stderr)
                return 8
            }

            let clampedUsage = try UsageSnapshotParser.windows(from: [
                "rateLimits": ["primary": ["usedPercent": 120]],
            ])
            guard clampedUsage == [
                UsageWindowDisplay(
                    label: "主要额度",
                    remainingPercent: 0,
                    durationMinutes: nil,
                    resetsAt: nil
                ),
            ] else {
                fputs("SELF_TEST_FAILED usage clamping\n", stderr)
                return 9
            }

            let weeklyOnlyUsage = try UsageSnapshotParser.windows(from: [
                "rateLimits": [
                    "primary": [
                        "usedPercent": 3,
                        "windowDurationMins": 10_080,
                        "resetsAt": 4_102_704_000,
                    ],
                    "secondary": NSNull(),
                ],
            ])
            guard weeklyOnlyUsage.count == 1,
                  weeklyOnlyUsage.first?.label == "每周" else {
                fputs("SELF_TEST_FAILED optional five-hour usage\n", stderr)
                return 9
            }

            let unreadFixture = Data("""
            {
              "electron-persisted-atom-state": {
                "unread-thread-ids-by-host-v1": {
                  "local": [
                    "00000000-0000-0000-0000-000000000001",
                    "invalid"
                  ],
                  "remote": [
                    "00000000-0000-0000-0000-000000000002"
                  ]
                }
              }
            }
            """.utf8)
            guard UnreadTaskStateRepository.unreadThreadIDs(from: unreadFixture) == Set([
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
            ]),
            UnreadTaskStateRepository.unreadThreadIDs(from: Data("not json".utf8)).isEmpty else {
                fputs("SELF_TEST_FAILED unread state parsing\n", stderr)
                return 11
            }
            var readAcknowledgements = ["read-thread": Int64(1000)]
            let acknowledgedTasks = ReadAcknowledgementPolicy.apply(
                to: [
                    CodexTask(
                        id: "read-thread",
                        title: "read-thread",
                        cwd: "/tmp",
                        gitBranch: "",
                        updatedMillis: 1000,
                        hasUnreadUpdate: true
                    ),
                    CodexTask(
                        id: "new-update-thread",
                        title: "new-update-thread",
                        cwd: "/tmp",
                        gitBranch: "",
                        updatedMillis: 2000,
                        hasUnreadUpdate: true
                    ),
                ],
                acknowledgements: &readAcknowledgements
            )
            guard acknowledgedTasks.first?.hasUnreadUpdate == false,
                  acknowledgedTasks.last?.hasUnreadUpdate == true,
                  readAcknowledgements["read-thread"] == Int64(1000) else {
                fputs("SELF_TEST_FAILED read acknowledgement hides stale unread\n", stderr)
                return 11
            }
            let refreshedAfterNewUpdate = ReadAcknowledgementPolicy.apply(
                to: [
                    CodexTask(
                        id: "read-thread",
                        title: "read-thread",
                        cwd: "/tmp",
                        gitBranch: "",
                        updatedMillis: 1001,
                        hasUnreadUpdate: true
                    ),
                ],
                acknowledgements: &readAcknowledgements
            )
            guard refreshedAfterNewUpdate.first?.hasUnreadUpdate == true,
                  readAcknowledgements["read-thread"] == nil else {
                fputs("SELF_TEST_FAILED read acknowledgement preserves new unread\n", stderr)
                return 11
            }

            let runningFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_complete"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"message"}}
            """.utf8)
            let completedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """.utf8)
            let abortedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"turn_aborted"}}
            """.utf8)
            let actionFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
            """.utf8)
            let resumedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
            {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}
            """.utf8)
            let approvalFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-2","arguments":"{\\"sandbox_permissions\\":\\"require_escalated\\"}"}}
            """.utf8)
            guard RolloutTaskStateRepository.state(from: runningFixture) == .running,
                  RolloutTaskStateRepository.state(from: completedFixture) == .idle,
                  RolloutTaskStateRepository.state(from: abortedFixture) == .idle,
                  RolloutTaskStateRepository.state(from: actionFixture) == .needsAction,
                  RolloutTaskStateRepository.state(from: resumedFixture) == .running,
                  RolloutTaskStateRepository.state(from: approvalFixture) == .needsAction,
                  RolloutTaskStateRepository.state(from: Data("not json".utf8)) == .unknown else {
                fputs("SELF_TEST_FAILED runtime state parsing\n", stderr)
                return 15
            }

            guard TaskDisplayState.resolve(runtimeState: .running, hasUnreadUpdate: true) == .running,
                  TaskDisplayState.resolve(runtimeState: .needsAction, hasUnreadUpdate: true) == .needsAction,
                  TaskDisplayState.resolve(runtimeState: .idle, hasUnreadUpdate: true) == .needsReview,
                  TaskDisplayState.resolve(runtimeState: .idle, hasUnreadUpdate: false) == .idle,
                  TaskDisplayState.resolve(runtimeState: .unknown, hasUnreadUpdate: true) == .needsReview else {
                fputs("SELF_TEST_FAILED display state priority\n", stderr)
                return 16
            }

            let unreadUpdateCount = tasks.filter(\.hasUnreadUpdate).count
            print("SELF_TEST_OK count=\(tasks.count)\(titleOverrideStatus)\(unreadOverrideStatus)\(readOverrideStatus)\(runtimeOverrideStatus)\(actionOverrideStatus) usage=ok unread_state=ok runtime_state=ok display_state=ok unread_update_count=\(unreadUpdateCount) database=\(result.databaseURL.path)")
            return 0
        } catch {
            fputs("SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

enum UsageClientSelfTest {
    static func run(expectFixtureValues: Bool = true) -> Int32 {
        let client = CodexUsageClient()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedResult: Result<UsageSnapshot, Error>?

        client.refresh { result in
            lock.lock()
            capturedResult = result
            lock.unlock()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 18) == .success else {
            client.stop()
            fputs("USAGE_SELF_TEST_FAILED timeout\n", stderr)
            return 10
        }
        client.stop()
        lock.lock()
        let result = capturedResult
        lock.unlock()

        switch result {
        case let .success(snapshot):
            guard !expectFixtureValues || (
                snapshot.windows == [
                    UsageWindowDisplay(
                        label: "5 小时",
                        remainingPercent: 65,
                        durationMinutes: 300,
                        resetsAt: Date(timeIntervalSince1970: 4_102_444_800)
                    ),
                    UsageWindowDisplay(
                        label: "每周",
                        remainingPercent: 10,
                        durationMinutes: 10_080,
                        resetsAt: Date(timeIntervalSince1970: 4_102_704_000)
                    ),
                ]
                && snapshot.planType == "prolite"
                && snapshot.resetCreditCount == 1
                && snapshot.dailyBuckets == [
                    UsageDailyBucket(dateKey: "2099-12-31", tokens: 12_000_000),
                    UsageDailyBucket(dateKey: "2100-01-01", tokens: 15_000_000),
                ]
                && snapshot.localEstimate.mostUsedModel == "gpt-5.5"
                && snapshot.localEstimate.inputPricePerMillionTokens == 5.0
            ) else {
                fputs("USAGE_SELF_TEST_FAILED unexpected values\n", stderr)
                return 11
            }
            print(
                expectFixtureValues
                    ? "USAGE_SELF_TEST_OK windows=2 analytics=ok"
                    : "USAGE_PROBE_OK windows=\(snapshot.windows.count) analytics=\(snapshot.dailyBuckets.count)"
            )
            return 0
        case let .failure(error):
            fputs("USAGE_SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 12
        case nil:
            fputs("USAGE_SELF_TEST_FAILED no result\n", stderr)
            return 13
        }
    }
}

@main
struct CodexRecentTasksMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Darwin.exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--usage-self-test") {
            Darwin.exit(UsageClientSelfTest.run())
        }
        if CommandLine.arguments.contains("--usage-probe") {
            Darwin.exit(UsageClientSelfTest.run(expectFixtureValues: false))
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
