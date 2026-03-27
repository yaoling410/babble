import Foundation

#if BABBLE_ON_DEVICE
@available(iOS 13.0, *)
final class ModelManager {
    static let shared = ModelManager()

    private let fileManager = FileManager.default
    private init() {}

    /// Returns a local URL for the named model. If the model file isn't present this method
    /// currently throws; in a full implementation it would trigger an async download and
    /// return once available.
    func modelURL(for name: String) async throws -> URL {
        let dir = try applicationSupportDirectory()
        let modelsDir = dir.appendingPathComponent("OnDeviceModels", isDirectory: true)
        if !fileManager.fileExists(atPath: modelsDir.path) {
            try fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }

        // Common file naming: <name>.model (placeholder)
        let modelFile = modelsDir.appendingPathComponent("\(name).model")

        // If file exists return it.
        if fileManager.fileExists(atPath: modelFile.path) {
            return modelFile
        }

        // For now, throw to indicate not downloaded. Callers should handle and fall back.
        throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found: \(name)"])
    }

    private func applicationSupportDirectory() throws -> URL {
        #if os(iOS)
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        #endif
        throw NSError(domain: "ModelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory"])    }
}
#endif
