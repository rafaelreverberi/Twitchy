import XCTest

final class TVNavigationTests: XCTestCase {
    @MainActor private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication(); app.launchEnvironment["TWITCHY_TV_SCREEN"] = screen; app.launch(); return app
    }
    @MainActor private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        guard target.waitForExistence(timeout: 10) else { XCTFail("Missing \(target.label)"); return }
        for _ in 0..<20 {
            if target.hasFocus { return }
            let focused = app.descendants(matching: .any).allElementsBoundByIndex.first { $0.hasFocus }
            guard let focused else { XCUIRemote.shared.press(.down); continue }
            let a = focused.frame, b = target.frame
            if abs(a.midY - b.midY) > 25 { XCUIRemote.shared.press(a.midY < b.midY ? .down : .up) }
            else { XCUIRemote.shared.press(a.midX < b.midX ? .right : .left) }
        }
        XCTAssertTrue(target.hasFocus, "Cannot focus \(target.label)")
    }
    @MainActor func testTelevisionScreens() {
        for (route, title) in [("onboarding", "Your streams.\nOn the big screen."), ("onboarding-code", "TVTEST42"), ("Home", "Watch now"), ("Channels", "Following"), ("Search", "Search"), ("Settings", "Settings"), ("channel", "Northern Lights")] {
            let app = launch(route)
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 15), route)
            XCTAssertFalse(app.buttons["Downloads"].exists)
            XCTAssertFalse(app.buttons["Library"].exists)
            XCTAssertFalse(app.staticTexts["Favorites"].exists)
            XCTAssertFalse(app.buttons["Add favorite"].exists)
            XCTAssertFalse(app.buttons["Remove favorite"].exists)
            capture(route)
            if route == "Settings" { XCTAssertTrue(app.buttons["tv.sync"].exists); XCTAssertTrue(app.buttons["tv.sources"].exists) }
            if route == "Home" {
                XCTAssertTrue(app.buttons["tv.featured"].exists)
                // Viewing history must outrank the first popular/followed stream.
                XCTAssertTrue(app.buttons["tv.featured"].label.contains("Pixel Workshop"))
                XCTAssertTrue(app.buttons["tv.featured"].label.contains("for you"))
            }
            if route == "Channels" {
                XCTAssertTrue(app.buttons["Northern Lights, live"].exists)
                XCTAssertTrue(app.buttons["Offline channel, offline"].exists)
            }
            XCTAssertFalse(app.buttons["Show chat"].exists)
            XCTAssertFalse(app.buttons["Enable chat"].exists)
            app.terminate()
        }
    }
    @MainActor func testFeaturedStreamStartsImmediatelyInFullscreen() throws {
        let before = try metrics()
        let app = launch("Home")
        let hero = app.buttons["tv.featured"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15))
        focus(hero, in: app); XCUIRemote.shared.press(.select)
        assertFullscreenPlayback(app)
        XCTAssertEqual(try requestedQuality(), "auto")
        capture("Featured fullscreen playback")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Watch now"].waitForExistence(timeout: 10))
        XCTAssertEqual(try metrics()["session_creations"], (before["session_creations"] ?? 0) + 1)
        XCTAssertEqual(try metrics()["session_deletions"], (before["session_deletions"] ?? 0) + 1)
    }
    @MainActor func testChannelsOpenProfileBeforeWatchLive() throws {
        let app = launch("Channels")
        for name in ["Northern Lights, live", "Watch Northern Lights, live, Science & Technology"] {
            let before = try metrics()
            let channel = app.buttons[name].firstMatch
            focus(channel, in: app); capture("Focused live card"); XCUIRemote.shared.press(.select)
            let watch = app.buttons["tv.watchLive"]
            XCTAssertTrue(watch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["tv.player"].exists)
            XCTAssertEqual(try metrics()["session_creations"], before["session_creations"])
            capture("Live channel profile")
            focus(watch, in: app); XCUIRemote.shared.press(.select)
            assertFullscreenPlayback(app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.staticTexts["Following"].waitForExistence(timeout: 10))
            XCTAssertEqual(try metrics()["session_creations"], (before["session_creations"] ?? 0) + 1)
            XCTAssertEqual(try metrics()["session_deletions"], (before["session_deletions"] ?? 0) + 1)
        }
    }
    @MainActor func testRecordingCardOpensFullscreen() {
        let app = launch("channel")
        let video = app.buttons["Building something together"]
        focus(video, in: app); capture("Focused recording card"); XCUIRemote.shared.press(.select)
        assertFullscreenPlayback(app)
        XCUIRemote.shared.press(.menu)
    }
    @MainActor func testStartingHasOneWhiteSpinnerWithoutText() {
        let app = launch("starting")
        XCTAssertTrue(app.descendants(matching: .any)["tv.starting"].firstMatch.waitForExistence(timeout: 10))
        // tvOS exposes the SwiftUI activity spinner as Other, not ProgressIndicator.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tv.starting").count, 1)
        XCTAssertFalse(app.staticTexts["Starting stream…"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tv.player"].exists)
        capture("Starting spinner")
        assertFullscreenPlayback(app)
        XCUIRemote.shared.press(.menu)
    }
    @MainActor func testSettingsRoutesUseTheWholeScreen() {
        let app = launch("Settings")
        let sources = app.buttons["tv.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        focus(sources, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Streaming sources"].waitForExistence(timeout: 10)); capture("Sources")
        let add = app.buttons["Add source"]
        focus(add, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Add streaming source"].waitForExistence(timeout: 10)); capture("Source editor")
        XCTAssertTrue(app.textFields["HTTPS base URL"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Streaming sources"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["tv.sources"].waitForExistence(timeout: 10))
    }
    @MainActor func testSecondaryTelevisionRoutes() {
        let app = launch("Settings")
        let quality = app.buttons["Video quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: 15)); focus(quality, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["tv.quality.auto"].waitForExistence(timeout: 10)); capture("Video quality settings")
        XCUIRemote.shared.press(.menu)
        let advanced = app.buttons["Advanced Twitch settings"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15))
        focus(advanced, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Twitch application"].waitForExistence(timeout: 10)); capture("Advanced settings")
        XCUIRemote.shared.press(.menu)
        let about = app.buttons["About Twitchy"]
        focus(about, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Your streams. Your way."].waitForExistence(timeout: 10)); capture("About")
        let privacy = app.buttons["Privacy"]
        focus(privacy, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["tv.title.Privacy"].waitForExistence(timeout: 10)); capture("Privacy")
        XCUIRemote.shared.press(.menu)
        let license = app.buttons["License"]
        focus(license, in: app); XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["tv.title.License"].waitForExistence(timeout: 10)); capture("License")
        app.terminate()
        let home = launch("Home")
        let category = home.buttons["Minecraft"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 15)); focus(category, in: home); capture("Focused game card"); XCUIRemote.shared.press(.select)
        XCTAssertTrue(home.staticTexts["Live channels"].waitForExistence(timeout: 10)); capture("Category")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(home.staticTexts["Watch now"].waitForExistence(timeout: 10))
    }
    private func metrics() throws -> [String: Int] {
        try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: URL(string: "http://localhost:8181/__test__/metrics")!))
    }
    private func requestedQuality() throws -> String? {
        let data = try Data(contentsOf: URL(string: "http://localhost:8181/__test__/playback-quality")!)
        return try JSONDecoder().decode([String: String?].self, from: data)["quality"] ?? nil
    }
    @MainActor private func assertFullscreenPlayback(_ app: XCUIApplication) {
        let player = app.descendants(matching: .any)["tv.player"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "value BEGINSWITH 'playing|'"), evaluatedWith: player)
        waitForExpectations(timeout: 25)
        XCTAssertEqual(player.frame.minX, 0, accuracy: 1)
        XCTAssertEqual(player.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(player.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(player.frame.height, app.frame.height, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Stream chat"].exists)
        XCTAssertFalse(app.textFields["chat.input"].exists)
        XCTAssertFalse(app.buttons["Fullscreen"].exists)
        XCTAssertFalse(app.buttons["Show chat"].exists)
        XCTAssertFalse(app.buttons["Hide chat"].exists)
        XCTAssertFalse(app.buttons["360p"].exists)
    }
    @MainActor func testPlayerUsesSourceAndCleansUpWhenClosed() throws {
        let before = try metrics()
        let app = launch("player")
        assertFullscreenPlayback(app)
        XCTAssertEqual(try requestedQuality(), "auto")
        capture("Fullscreen player")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Watch now"].waitForExistence(timeout: 10))
        XCTAssertEqual(try metrics()["session_creations"], (before["session_creations"] ?? 0) + 1)
        XCTAssertEqual(try metrics()["session_deletions"], (before["session_deletions"] ?? 0) + 1)
    }
    @MainActor func testConfiguredQualityIsUsedInFullscreen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_TV_SCREEN"] = "player"
        app.launchEnvironment["TWITCHY_TV_QUALITY"] = "360p"
        app.launch()
        assertFullscreenPlayback(app)
        XCTAssertEqual(try requestedQuality(), "360p")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Watch now"].waitForExistence(timeout: 10))
    }
}
