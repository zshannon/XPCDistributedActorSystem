import Foundation

public extension Bundle {
    func firstXPCServiceIdentifier() -> String? {
        let xpcPath = bundleURL.appending(components: "Contents", "XPCServices", directoryHint: .isDirectory)

        guard
            let contents = try? FileManager.default.contentsOfDirectory(at: xpcPath, includingPropertiesForKeys: nil),
            let firstXPCService = contents.first(where: { $0.pathExtension == "xpc" }),
            let serviceBundle = Bundle(url: firstXPCService)
        else {
            return nil
        }

        return serviceBundle.bundleIdentifier
    }
}
