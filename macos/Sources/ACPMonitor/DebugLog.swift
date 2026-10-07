import Foundation

/// Appends diagnostic lines to a file for the ACP_LYNK_DEBUG_* switches.
/// Kept out of AppModel, which owns no filesystem primitives.
enum DebugLog {
    static func append(_ line: String, to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}
