import XCTest
@testable import UpkeepCore

final class PathValidatorTests: XCTestCase {
    var fixture: Fixture!
    var fs: LocalFileSystem!
    var validator: PathValidator!
    var caches: URL!

    override func setUpWithError() throws {
        fixture = try Fixture()
        fs = LocalFileSystem()
        validator = PathValidator(fileSystem: fs, protectedPaths: ProtectedPaths(homeDirectory: fixture.home, fileSystem: fs))
        caches = try fixture.dir("Library/Caches")
    }

    override func tearDown() {
        fixture = nil
    }

    func testChildOfRootIsValid() throws {
        let item = try fixture.dir("Library/Caches/com.example.App")
        let validated = try validator.validate(item, within: caches)
        XCTAssertEqual(validated.components, ["com.example.App"])
        XCTAssertEqual(validated.path, try fs.canonicalPath(item))
    }

    func testNestedChildKeepsAllComponents() throws {
        let item = try fixture.dir("Library/Caches/org.swift.swiftpm/repositories")
        let validated = try validator.validate(item, within: caches)
        XCTAssertEqual(validated.components, ["org.swift.swiftpm", "repositories"])
    }

    func testRootItselfIsRejected() throws {
        XCTAssertThrowsError(try validator.validate(caches, within: caches)) { error in
            XCTAssertEqual(error as? FileSystemError, .outsideApprovedRoot(caches.path))
        }
    }

    func testParentTraversalIsRejected() throws {
        try fixture.file("secret.txt", in: fixture.outside)
        let sneaky = URL(fileURLWithPath: caches.path + "/../../../outside/secret.txt")
        XCTAssertThrowsError(try validator.validate(sneaky, within: caches)) { error in
            XCTAssertEqual(error as? FileSystemError, .invalidPath(sneaky.path))
        }
    }

    func testDotComponentIsRejected() throws {
        let dotted = URL(fileURLWithPath: caches.path + "/./com.example.App")
        XCTAssertThrowsError(try validator.validate(dotted, within: caches))
    }

    func testItemOutsideRootIsRejected() throws {
        let other = try fixture.dir("Documents/Project")
        XCTAssertThrowsError(try validator.validate(other, within: caches)) { error in
            XCTAssertEqual(error as? FileSystemError, .outsideApprovedRoot(other.path))
        }
    }

    func testSymlinkedParentPointingOutsideIsRejected() throws {
        let target = try fixture.dir("victim", in: fixture.outside)
        try fixture.file("victim/important.txt", in: fixture.outside)
        let link = try fixture.symlink("Library/Caches/com.evil.App", to: target)
        let throughLink = link.appendingPathComponent("important.txt")
        XCTAssertThrowsError(try validator.validate(throughLink, within: caches)) { error in
            XCTAssertEqual(error as? FileSystemError, .outsideApprovedRoot(throughLink.path))
        }
    }

    func testMissingParentReportsNotFound() throws {
        let missing = caches.appendingPathComponent("gone/child")
        XCTAssertThrowsError(try validator.validate(missing, within: caches)) { error in
            XCTAssertEqual(error as? FileSystemError, .notFound(missing.path))
        }
    }

    func testSensitiveComponentsAreProtected() throws {
        for name in [".git", ".ssh", ".env", "id_rsa", "login.keychain-db", ".env.local"] {
            let url = caches.appendingPathComponent(name)
            try Data().write(to: url)
            XCTAssertThrowsError(try validator.validate(url, within: caches), name) { error in
                guard case .protectedPath = error as? FileSystemError else {
                    return XCTFail("\(name): expected protectedPath, got \(error)")
                }
            }
        }
    }

    func testProtectedUserFoldersCannotBeTargeted() throws {
        let documents = try fixture.dir("Documents")
        // Even with the home folder as the root, Documents itself and its contents are off limits.
        XCTAssertThrowsError(try validator.validate(documents, within: fixture.home))
        let inside = try fixture.dir("Documents/Taxes")
        XCTAssertThrowsError(try validator.validate(inside, within: fixture.home))
        let keychains = try fixture.dir("Library/Keychains")
        XCTAssertThrowsError(try validator.validate(keychains, within: fixture.home))
    }

    func testExplicitlyApprovedFolderInsideProtectedAreaIsAllowed() throws {
        let project = try fixture.dir("Documents/Code/app")
        let pycache = try fixture.dir("Documents/Code/app/__pycache__")
        let validated = try validator.validate(pycache, within: project)
        XCTAssertEqual(validated.components, ["__pycache__"])
    }

    func testPathsWithSpacesAndUnicodeValidate() throws {
        let spaced = try fixture.dir("Library/Caches/com.example.My App")
        XCTAssertEqual(try validator.validate(spaced, within: caches).components, ["com.example.My App"])
        let unicode = try fixture.dir("Library/Caches/com.例え.キャッシュ-é")
        XCTAssertEqual(try validator.validate(unicode, within: caches).components, ["com.例え.キャッシュ-é"])
    }

    func testProtectedPathsCheckRules() throws {
        let protected = ProtectedPaths(paths: ["/Users/me", "/Users/me/Documents", "/System"])
        // Item that *is* protected.
        XCTAssertThrowsError(try protected.check(fullPath: "/Users/me/Documents", rootPath: "/Users/me", relativeComponents: ["Documents"]))
        // Item that *contains* something protected.
        XCTAssertThrowsError(try protected.check(fullPath: "/Users", rootPath: "/", relativeComponents: ["Users"]))
        // Inside a protected area without an approved root inside it.
        XCTAssertThrowsError(try protected.check(fullPath: "/Users/me/Documents/a", rootPath: "/Users/me", relativeComponents: ["Documents", "a"]))
        // Inside a protected area whose approved root is more specific.
        XCTAssertNoThrow(try protected.check(fullPath: "/Users/me/Documents/code/x", rootPath: "/Users/me/Documents/code", relativeComponents: ["x"]))
        // System files.
        XCTAssertThrowsError(try protected.check(fullPath: "/System/Library/x", rootPath: "/Users/me/Library/Caches", relativeComponents: ["x"]))
    }
}
