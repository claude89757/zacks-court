import Foundation
import XCTest
@testable import CourtCore

final class AnalysisModelLocatorTests: XCTestCase {
    private func fixture(mode: String) throws -> (URL, Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.court.fixture.\(UUID().uuidString)",
                                  "CFBundleName": "Fixture", "CFBundlePackageType": "APPL",
                                  "CourtModelSet": mode]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let privateModels = resources.appendingPathComponent("AnalysisModels")
        try FileManager.default.createDirectory(at: privateModels, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: privateModels.appendingPathComponent("manifest.json"))
        return (root, try XCTUnwrap(Bundle(url: app)), privateModels)
    }

    func testIndependentModeRejectsPrivateEnvironmentAndBundleResources() throws {
        let (root, bundle, models) = try fixture(mode: "independent")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: ["COURT_ANALYSIS_MODELS_DIR": models.path]))
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: [:]))
    }

    func testCodeOnlyModeRejectsPrivateEnvironmentAndBundleResources() throws {
        let (root, bundle, models) = try fixture(mode: "code-only")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: ["COURT_ANALYSIS_MODELS_DIR": models.path]))
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: [:]))
    }

    func testSjiaModeRetainsExplicitModelOverride() throws {
        let (root, bundle, _) = try fixture(mode: "sjia")
        defer { try? FileManager.default.removeItem(at: root) }
        let explicit = root.appendingPathComponent("ExplicitModels")
        try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: explicit.appendingPathComponent("manifest.json"))
        XCTAssertEqual(AnalysisModelLocator.directory(in: bundle, environment: ["COURT_ANALYSIS_MODELS_DIR": explicit.path])?.path, explicit.path)
    }

    func testSjiaModeUsesBundleAndRejectsMissingExplicitDirectory() throws {
        let (root, bundle, models) = try fixture(mode: "sjia")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AnalysisModelLocator.directory(in: bundle, environment: [:])?.path, models.path)
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: ["COURT_ANALYSIS_MODELS_DIR": root.appendingPathComponent("missing").path]))
    }

    /// A build carrying both sets loads the S家 weights only while S家 is selected; S家 is the default.
    func testBothModeFollowsTheSavedBackend() throws {
        let (root, bundle, models) = try fixture(mode: "both")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "court.backend.test.\(UUID().uuidString)"))
        XCTAssertEqual(CourtAnalysisBackend.current(defaults), .sjia)
        XCTAssertEqual(CourtAnalysisBackend.bundled(in: bundle), [.sjia, .independent])
        XCTAssertEqual(AnalysisModelLocator.directory(in: bundle, environment: [:], defaults: defaults)?.path, models.path)
        CourtAnalysisBackend.save(.independent, defaults)
        XCTAssertEqual(CourtAnalysisBackend.effective(in: bundle, defaults: defaults), .independent)
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: [:], defaults: defaults))
        XCTAssertNil(AnalysisModelLocator.directory(in: bundle, environment: ["COURT_ANALYSIS_MODELS_DIR": models.path], defaults: defaults))
        defaults.set("unknown", forKey: CourtAnalysisBackend.defaultsKey)
        XCTAssertEqual(CourtAnalysisBackend.current(defaults), .sjia)
        // Installs from before the rename saved S家 as "swing"; an old build's Info.plist said "swing" too.
        CourtAnalysisBackend.save(.independent, defaults)
        defaults.set("swing", forKey: CourtAnalysisBackend.defaultsKey)
        XCTAssertEqual(CourtAnalysisBackend.current(defaults), .sjia)
        let (root2, oldName, _) = try fixture(mode: "swing")
        defer { try? FileManager.default.removeItem(at: root2) }
        XCTAssertEqual(CourtAnalysisBackend.bundled(in: oldName), [.sjia])
    }

    func testSingleSetBuildsIgnoreASavedChoiceTheyCannotHonour() throws {
        let (root, bundle, _) = try fixture(mode: "independent")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "court.backend.test.\(UUID().uuidString)"))
        XCTAssertEqual(CourtAnalysisBackend.effective(in: bundle, defaults: defaults), .independent)
        let (root2, sjiaOnly, _) = try fixture(mode: "sjia")
        defer { try? FileManager.default.removeItem(at: root2) }
        CourtAnalysisBackend.save(.independent, defaults)
        XCTAssertEqual(CourtAnalysisBackend.effective(in: sjiaOnly, defaults: defaults), .sjia)
    }
}
