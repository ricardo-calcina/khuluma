import Foundation
import Testing
@testable import KhulumaCore

struct CLIIdentityTests {
  private func identity(binary: String = "/fixture/bin/khuluma", root: String = "/fixture/config", migration: Bool = false) throws -> CLIIdentity {
    let data = try JSONSerialization.data(withJSONObject: [
      "running_binary": ["path": binary],
      "identity": ["product": "khuluma", "identity_version": 1,
                   "canonical_binary": binary, "config_dir": root, "migration_required": migration],
    ])
    return try CLIIdentity.decodeVersion(data, isExecutable: { $0 == binary })
  }

  @Test func contractThreeWithoutCanonicalIdentityIsRejected() throws {
    let old = Data(#"{"app_contract":3,"running_binary":{"path":"/old/bin/tmux-whisper"}}"#.utf8)
    #expect(throws: CLIIdentity.Invalid.self) { try CLIIdentity.decodeVersion(old, isExecutable: { _ in true }) }
    #expect(throws: CLIIdentity.Invalid.self) { try identity(binary: "/old/bin/tmux-whisper") }
    #expect(throws: CLIIdentity.Invalid.self) { try identity(migration: true) }
  }

  @Test func canonicalIdentityAndAppConfigMustChooseTheSameRoot() throws {
    let probe = try identity()
    try probe.validateConfigRoot("/fixture/config")
    #expect(throws: CLIIdentity.Invalid.self) { try probe.validateConfigRoot("/different/config") }
  }

  @Test func canonicalLocalInstallationIsSelectedFirst() throws {
    var inspected: [String] = []
    let selected = try CLISelection.locate(explicit: nil, home: "/fixture", isExecutable: { _ in true }) { path in
      inspected.append(path)
      return try identity(binary: path)
    }
    #expect(selected?.canonicalBinary == "/fixture/.local/bin/khuluma")
    #expect(inspected == ["/fixture/.local/bin/khuluma"])
  }

  @Test func staleLocalCLIDoesNotHideACompatibleHomebrewInstallation() throws {
    var inspected: [String] = []
    let selected = try CLISelection.locate(explicit: nil, home: "/fixture", isExecutable: { _ in true }) { path in
      inspected.append(path)
      if path == "/opt/homebrew/bin/khuluma" { return try identity(binary: path) }
      throw CLIIdentity.Invalid.legacy
    }
    #expect(selected?.canonicalBinary == "/opt/homebrew/bin/khuluma")
    #expect(inspected == ["/fixture/.local/bin/khuluma", "/opt/homebrew/bin/khuluma"])
  }

  @Test func oldNameOnlyInstallationIsNeverProbedOrSelected() throws {
    var checked: [String] = []
    var inspected: [String] = []
    let selected = try CLISelection.locate(explicit: nil, home: "/fixture", isExecutable: { path in
      checked.append(path)
      return path.hasSuffix("tmux-whisper")
    }) { path in
      inspected.append(path)
      return try identity(binary: "/fixture/.local/bin/khuluma")
    }
    #expect(selected == nil)
    #expect(checked == ["/fixture/.local/bin/khuluma", "/opt/homebrew/bin/khuluma", "/usr/local/bin/khuluma"])
    #expect(inspected.isEmpty)
  }

  @Test func explicitIncompatibleOverrideFailsWithoutTryingOtherInstallations() {
    var inspected: [String] = []
    #expect(throws: CLISelection.Rejected.self) {
      try CLISelection.locate(explicit: "/chosen/old-cli", home: "/fixture", isExecutable: { _ in true }) { path in
        inspected.append(path)
        throw CLIIdentity.Invalid.legacy
      }
    }
    #expect(inspected == ["/chosen/old-cli"])
  }
}
