import BerthKit
import FileProvider
import Security
import os

/// The XPC endpoint the Berth app uses to configure this domain and report server-side changes.
///
/// Only Berth itself may connect: the peer must be signed with the app's identifier and, when
/// this extension is signed by a team, by the same team.
final class ControlService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, BerthCloudControl {
    let serviceName = NSFileProviderServiceName(BerthCloud.controlServiceName)
    private let listener = NSXPCListener.anonymous()
    private weak var host: FileProviderExtension?
    private let logger = Logger(subsystem: "app.berth.cloud", category: "control")

    init(host: FileProviderExtension) {
        self.host = host
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(Self.peerRequirement)
        connection.exportedInterface = NSXPCInterface(with: BerthCloudControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// `identifier "app.berth.Berth"`, plus the team when this extension has one.
    private static let peerRequirement: String = {
        let ownIdentifier = Bundle.main.bundleIdentifier ?? "app.berth.Berth.cloud"
        let appIdentifier = ownIdentifier.hasSuffix(".cloud") ? String(ownIdentifier.dropLast(6)) : "app.berth.Berth"
        var requirement = "identifier \"\(appIdentifier)\""
        if let team = teamIdentifier() {
            requirement = "anchor apple generic and \(requirement) and certificate leaf[subject.OU] = \"\(team)\""
        }
        return requirement
    }()

    private static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: BerthCloudControl

    func configure(_ configuration: Data, password: String?, reply: @escaping @Sendable (String?) -> Void) {
        guard let host, let engine = host.engine else {
            reply("Berth Cloud could not open its database.")
            return
        }
        do {
            let decoded = try JSONDecoder().decode(CloudDomainConfiguration.self, from: configuration)
            guard decoded.shareID.uuidString == host.domain.identifier.rawValue else {
                reply("The configuration is for a different location.")
                return
            }
            try engine.configure(decoded, password: password)
            logger.info("Configured for \(decoded.endpoint.host, privacy: .public)")
            host.signalChanges()
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func markDirty(_ paths: [String], recursive: Bool, reply: @escaping @Sendable () -> Void) {
        host?.engine?.markDirty(paths, recursive: recursive)
        reply()
    }

    func status(_ reply: @escaping @Sendable (Data?) -> Void) {
        guard let status = host?.engine?.status() else {
            reply(nil)
            return
        }
        reply(try? JSONEncoder().encode(status))
    }
}
