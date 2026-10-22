import Foundation

/// The identity envelope on `khuluma version --json`. The contract number
/// alone cannot establish the executable identity and authoritative data root.
public struct CLIIdentity: Decodable, Equatable, Sendable {
  public let product: String
  public let identityVersion: Int
  public let canonicalBinary: String
  public let configDir: String
  public let migrationRequired: Bool

  enum CodingKeys: String, CodingKey {
    case product
    case identityVersion = "identity_version"
    case canonicalBinary = "canonical_binary"
    case configDir = "config_dir"
    case migrationRequired = "migration_required"
  }

  private struct Version: Decodable {
    struct RunningBinary: Decodable { let path: String }
    let identity: CLIIdentity
    let runningBinary: RunningBinary
    enum CodingKeys: String, CodingKey {
      case identity
      case runningBinary = "running_binary"
    }
  }

  public enum Invalid: Error, LocalizedError {
    case legacy, binary, migration, root

    public var errorDescription: String? {
      switch self {
      case .legacy: return "the CLI does not identify itself as canonical khuluma; select or install the khuluma command"
      case .binary: return "the CLI identity does not resolve to an executable canonical khuluma binary; repair the installation"
      case .migration: return "Khuluma data migration is required; run tools/migrate-khuluma-identity.sh before launching the app"
      case .root: return "khuluma version and app-config selected different config roots; repair the CLI environment before dictating"
      }
    }
  }

  public static func decodeVersion(_ data: Data, isExecutable: (String) -> Bool) throws -> Self {
    guard let version = try? JSONDecoder().decode(Version.self, from: data),
          version.identity.product == "khuluma", version.identity.identityVersion == 1 else {
      throw Invalid.legacy
    }
    let identity = version.identity
    guard identity.canonicalBinary.hasPrefix("/"),
          URL(fileURLWithPath: identity.canonicalBinary).lastPathComponent == "khuluma",
          version.runningBinary.path == identity.canonicalBinary,
          isExecutable(identity.canonicalBinary), identity.configDir.hasPrefix("/") else {
      throw Invalid.binary
    }
    guard !identity.migrationRequired else { throw Invalid.migration }
    return identity
  }

  public func validateConfigRoot(_ root: String) throws {
    guard configDir == root else { throw Invalid.root }
  }
}

/// The probe must verify identity, root and app contract before returning a
/// canonical local/Homebrew candidate. An explicit override never silently
/// falls back to a different installation.
public enum CLISelection {
  public struct Rejected: Error, LocalizedError {
    public let path: String
    public let reason: String
    public var errorDescription: String? { "Cannot use \(path): \(reason)" }
  }

  public static func locate(
    explicit: String?, home: String, isExecutable: (String) -> Bool,
    inspect: (String) throws -> CLIIdentity
  ) throws -> CLIIdentity? {
    if let explicit, !explicit.isEmpty {
      guard isExecutable(explicit) else {
        throw Rejected(path: explicit, reason: "KHULUMA_CLI is not executable; select the installed khuluma command")
      }
      do { return try inspect(explicit) }
      catch { throw Rejected(path: explicit, reason: error.localizedDescription) }
    }
    let roots = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    let candidates = roots.map { "\($0)/khuluma" }
    var rejection: Rejected?
    for candidate in candidates where isExecutable(candidate) {
      do { return try inspect(candidate) }
      catch { rejection = Rejected(path: candidate, reason: error.localizedDescription) }
    }
    if let rejection { throw rejection }
    return nil
  }
}
