import Foundation
import Darwin
import Testing
@testable import KhulumaCore

struct AppRuntimePathsTests {
  private let home = URL(fileURLWithPath: "/Users/fixture")

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-isolation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let path = try #require(realpath(root.path, nil))
    defer { free(path) }
    // Generated roots are retained; no daily application state is inspected.
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }

  private func environment(_ root: URL) -> [String: String] {
    ["KHULUMA_SUPPORT_DIR": root.appendingPathComponent("support").path,
     "KHULUMA_LOG_DIR": root.appendingPathComponent("logs").path,
     "KHULUMA_DEFAULTS_SUITE": "com.ricardo-nth.khuluma.fixture.\(UUID().uuidString)"]
  }

  @Test func ordinaryDefaultsStayAtTheExistingKhulumaLocations() {
    #expect(!AppRuntimePaths.isIsolated(environment: [:]))
    #expect(AppRuntimePaths.isolationIssue(environment: [:], home: home) == nil)
    #expect(AppRuntimePaths.supportDirectory(environment: [:], home: home).path == "/Users/fixture/Library/Application Support/Khuluma")
    #expect(AppRuntimePaths.logDirectory(environment: [:], home: home).path == "/Users/fixture/Library/Logs/Khuluma")
  }

  @Test func createsOnlyPrivateChildrenOfAnExistingPrivateFixtureRoot() throws {
    let root = try fixture()
    let environment = self.environment(root)
    #expect(AppRuntimePaths.isolationIssue(environment: environment, home: home) == nil)
    try AppRuntimePaths.prepareIsolation(environment: environment, home: home)
    #expect(AppRuntimePaths.isolationIssue(environment: environment, home: home) == nil)
    #expect(AppRuntimePaths.supportDirectory(environment: environment, home: home).path == environment["KHULUMA_SUPPORT_DIR"])
    #expect(AppRuntimePaths.logDirectory(environment: environment, home: home).path == environment["KHULUMA_LOG_DIR"])
    for relative in ["support", "logs", "support/temporary"] {
      let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
  }

  @Test func rejectsPartialOverridesAndBroadOrDailyRootsWithoutCreatingState() throws {
    let root = try fixture()
    let incomplete = ["KHULUMA_SUPPORT_DIR": root.appendingPathComponent("support").path]
    #expect(throws: (any Error).self) { try AppRuntimePaths.prepareIsolation(environment: incomplete, home: home) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    for path in ["/", home.path, "/System", "/Library", home.appendingPathComponent("Documents").path,
                 home.appendingPathComponent("Library/Application Support").path,
                 home.appendingPathComponent("Library/Application Support/Khuluma").path,
                 home.appendingPathComponent("Library/Application Support/Khuluma/recovered").path,
                 home.appendingPathComponent("Library/Logs/Khuluma").path,
                 home.appendingPathComponent(".config/khuluma").path] {
      #expect(AppRuntimePaths.isolationIssue(environment: environment(URL(fileURLWithPath: path)), home: home) != nil)
    }
    var unsafe = environment(root)
    unsafe["KHULUMA_DEFAULTS_SUITE"] = "com.ricardo-nth.khuluma"
    #expect(AppRuntimePaths.isolationIssue(environment: unsafe, home: home) != nil)
  }

  @Test func rejectsOverlappingRootsAndTraversal() throws {
    let root = try fixture()
    var unsafe = environment(root)
    unsafe["KHULUMA_LOG_DIR"] = unsafe["KHULUMA_SUPPORT_DIR"]
    #expect(AppRuntimePaths.isolationIssue(environment: unsafe, home: home) != nil)
    unsafe["KHULUMA_LOG_DIR"] = root.appendingPathComponent("support/logs").path
    #expect(AppRuntimePaths.isolationIssue(environment: unsafe, home: home) != nil)
    unsafe = environment(root)
    unsafe["KHULUMA_SUPPORT_DIR"] = root.path + "/child/../support"
    #expect(AppRuntimePaths.isolationIssue(environment: unsafe, home: home) != nil)
  }

  @Test func rejectsTemporaryDirectoryAliasesWithoutNormalizingThemAway() throws {
    let root = try fixture()
    let alias = FileManager.default.temporaryDirectory.appendingPathComponent(root.lastPathComponent)
    if alias.path != root.path {
      #expect(AppRuntimePaths.isolationIssue(environment: environment(alias), home: home) != nil)
    }
  }

  @Test func rejectsNonprivateAndWrongOwnerRoots() throws {
    let root = try fixture()
    let environment = self.environment(root)
    #expect(AppRuntimePaths.isolationIssue(environment: environment, home: home, expectedOwner: getuid() + 1) != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    #expect(AppRuntimePaths.isolationIssue(environment: environment, home: home) != nil)
    let other = try fixture()
    let otherEnvironment = self.environment(other)
    try AppRuntimePaths.prepareIsolation(environment: otherEnvironment, home: home)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: other.appendingPathComponent("logs").path)
    #expect(AppRuntimePaths.isolationIssue(environment: otherEnvironment, home: home) != nil)
  }

  @Test func rejectsSymlinkedRootsAncestorsAndTemporaryDirectory() throws {
    let root = try fixture()
    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(AppRuntimePaths.isolationIssue(environment: environment(link), home: home) != nil)
    var symlinkRoot = environment(root)
    symlinkRoot["KHULUMA_LOG_DIR"] = link.path
    #expect(AppRuntimePaths.isolationIssue(environment: symlinkRoot, home: home) != nil)
    let stateRoot = try fixture()
    let state = environment(stateRoot)
    let support = stateRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("temporary"), withDestinationURL: real)
    #expect(throws: (any Error).self) { try AppRuntimePaths.prepareIsolation(environment: state, home: home) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
  }
}
