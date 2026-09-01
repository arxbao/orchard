import ContainerizationOCI
import Foundation

/// Docker credential-helper support (issue #7): registries like Google
/// Artifact Registry or ECR hand out short-lived tokens via helpers
/// (`docker-credential-gcloud` etc.) configured in ~/.docker/config.json.
///
/// The platform's pull daemon (container-core-images) reads credentials from
/// the keychain by hostname and can't be handed credentials per request — so
/// Davit resolves the helper *immediately before each pull* and writes the
/// fresh token into the keychain entry the daemon reads. The keychain is a
/// transport here, not a store: tokens are re-resolved every pull, so expiry
/// (~1 h for gcloud) never bites. Static keychain logins for hosts without a
/// helper entry are untouched.
enum DockerCredentialHelpers {

    private struct DockerConfig: Decodable {
        let credHelpers: [String: String]?
        let credsStore: String?
    }

    private struct HelperOutput: Decodable {
        let Username: String
        let Secret: String
    }

    /// Well-known locations for helper binaries; GUI apps get a minimal PATH.
    private static let searchPaths = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin",
        NSHomeDirectory() + "/google-cloud-sdk/bin",
        NSHomeDirectory() + "/.docker/bin",
    ]

    /// The helper configured for `host`, if any: an exact credHelpers match
    /// wins, otherwise the global credsStore.
    static func helperName(for host: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.docker/config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(DockerConfig.self, from: data) else { return nil }
        if let helper = config.credHelpers?[host] { return helper }
        // Docker Hub's legacy key form.
        if host == "docker.io" || host == "registry-1.docker.io" || host == "index.docker.io",
           let helper = config.credHelpers?["https://index.docker.io/v1/"] { return helper }
        return config.credsStore
    }

    /// If a credential helper covers the reference's registry, resolve fresh
    /// credentials and stage them in the keychain for the platform's pull
    /// daemon. Failures are logged, never fatal — the pull proceeds and fails
    /// with the registry's own error if credentials were truly needed.
    static func refreshCredentials(forReference reference: String) async {
        guard let host = try? Reference.parse(reference).domain, !host.isEmpty else { return }
        guard let helper = helperName(for: host) else { return }
        do {
            guard let credentials = try await resolve(host: host, helper: helper) else { return }
            let keychainHost = Reference.resolveDomain(domain: host)
            try RegistryService.saveTrustingPlatform(
                hostname: keychainHost,
                username: credentials.user,
                password: credentials.secret)
            Backend.log.info("credential helper staged fresh credentials", metadata: [
                "host": "\(host)", "helper": "\(helper)",
            ])
        } catch {
            Backend.log.warning("credential helper failed", metadata: [
                "host": "\(host)", "helper": "\(helper)", "error": "\(error)",
            ])
        }
    }

    /// Invoke `docker-credential-<helper> get`, piping the server on stdin —
    /// the protocol Docker itself uses.
    static func resolve(host: String, helper: String) async throws -> (user: String, secret: String)? {
        guard let binary = findHelper(helper) else {
            throw CLIError(command: "docker-credential-\(helper)",
                           message: "helper not found in \(searchPaths.joined(separator: ", "))")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["get"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + searchPaths.joined(separator: ":")
        process.environment = env

        try process.run()
        stdin.fileHandleForWriting.write(Data("\(host)\n".utf8))
        try? stdin.fileHandleForWriting.close()

        // Read + wait off the calling actor; helpers like gcloud can take seconds.
        let result: (data: Data, status: Int32, errText: String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (data, process.terminationStatus,
                                        String(decoding: err, as: UTF8.self)))
            }
        }
        guard result.status == 0 else {
            throw CLIError(command: "docker-credential-\(helper) get",
                           message: result.errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let output = try? JSONDecoder().decode(HelperOutput.self, from: result.data) else {
            throw CLIError(command: "docker-credential-\(helper) get", message: "unparseable helper output")
        }
        return (output.Username, output.Secret)
    }

    private static func findHelper(_ helper: String) -> String? {
        let name = "docker-credential-\(helper)"
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}