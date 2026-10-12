import XCTest
final class NavigationTests: XCTestCase {
    @MainActor private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    @MainActor private func selectDestination(_ name: String, in app: XCUIApplication) {
        #if os(macOS)
        activate(app.descendants(matching: .any)["nav." + name.lowercased()].firstMatch)
        #else
        activate(app.tabBars.buttons[name])
        #endif
    }
    @MainActor func testOfflineDiscoveryKeepsAccountAndOpensDownloads() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_DISCOVERY_FIXTURE"] = "offline"
        app.launch()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 10))
        let offlineCapture = XCTAttachment(screenshot: app.screenshot())
        offlineCapture.name = "Centered offline state"; offlineCapture.lifetime = .keepAlways; add(offlineCapture)
        for name in ["Home", "Channels", "Search"] {
            selectDestination(name, in: app)
            XCTAssertTrue(app.staticTexts["You’re offline"].exists)
            XCTAssertFalse(app.staticTexts["Your live lineup"].exists)
            XCTAssertFalse(app.buttons["Sign in with Twitch"].exists)
        }
        activate(app.buttons["home.downloads"])
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        selectDestination("Profile", in: app)
        XCTAssertTrue(app.staticTexts["Offline viewer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Signed in · Offline"].exists)
        XCTAssertFalse(app.buttons["Sign in with Twitch"].exists)
        activate(app.buttons["profile.settings"])
        XCTAssertTrue(app.staticTexts["Signed in as @offlineviewer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Signed in · Offline"].exists)
        XCTAssertFalse(app.buttons["oauth.signIn"].exists)
    }
    @MainActor func testDiscoveryShellAppearsBeforeLibraryLoads() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_DISCOVERY_FIXTURE"] = "loading"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.skeleton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        let loadingCapture = XCTAttachment(screenshot: app.screenshot())
        loadingCapture.name = "Discovery loading placeholders"; loadingCapture.lifetime = .keepAlways; add(loadingCapture)
        selectDestination("Channels", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["channels.skeleton"].firstMatch.exists)
        selectDestination("Downloads", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["channels.skeleton"].firstMatch.exists)
    }
    @MainActor func testSourcesSelectionEditAndCheckAreIndependent() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_DISCOVERY_FIXTURE"] = "offline"
        app.launchEnvironment["TWITCHY_UI_SOURCES_FIXTURE"] = "1"
        app.launch()
        let link = app.buttons["Streaming sources"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); activate(link)
        let backup = app.buttons["sources.select.Backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 5)); activate(backup)
        XCTAssertTrue(app.staticTexts["Using Backup"].waitForExistence(timeout: 5))
        activate(app.buttons["sources.edit.Primary"])
        let name = app.textFields["sources.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        activate(name); name.typeText(" renamed")
        XCTAssertEqual(name.value as? String, "Primary renamed")
        activate(app.buttons["sources.save"])
        XCTAssertTrue(app.buttons["sources.select.Primary renamed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Using Backup"].exists)
        activate(app.buttons["sources.check.Primary renamed"])
        XCTAssertFalse(app.textFields["sources.name"].exists)
        XCTAssertTrue(app.staticTexts["Using Backup"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Sources switching and independent controls"; capture.lifetime = .keepAlways; add(capture)
    }
    @MainActor func testWelcomeAndPrimaryNavigation() {
        let app = XCUIApplication(); app.launch()
        let start = app.buttons["onboarding.complete"]
        if start.waitForExistence(timeout: 5) { activate(start) }
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5))
        for name in ["Home", "Channels", "Search", "Downloads", "Profile"] {
            #if os(macOS)
            XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "Missing destination \(name)")
            #else
            if app.tabBars.firstMatch.exists {
                let tab = app.tabBars.buttons[name]
                XCTAssertTrue(tab.exists, "Missing destination \(name)")
                activate(tab)
                #if os(iOS)
                if name == "Search" {
                    let search = app.searchFields["Search Twitch"]
                    XCTAssertTrue(search.waitForExistence(timeout: 5))
                    XCTAssertTrue(search.isHittable, "Search must be visible immediately without scrolling")
                }
                #endif
            } else {
                let showSidebar = app.buttons["Show Sidebar"]
                if showSidebar.exists { activate(showSidebar) }
                XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "Missing destination \(name)")
            }
            #endif
        }
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Twitchy primary navigation"; capture.lifetime = .keepAlways; add(capture)
        activate(app.buttons["settings.open"])
        XCTAssertTrue(app.buttons["oauth.signIn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["oauth.clientID"].exists, "Client configuration should stay in Advanced settings")
    }
    #if os(macOS)
    @MainActor func testMacCompanionWaitingAndDismissal() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_COMPANION_FIXTURE"] = "idle"
        app.launch()
        let open = app.buttons["companion.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertTrue(app.staticTexts["Start a stream on your TV"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.open"].isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Mac Companion waiting"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["companion.close"].click()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
    @MainActor func testMacCompanionLiveChatNeedsOwnAuthorization() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_COMPANION_FIXTURE"] = "live"
        app.launch()
        let open = app.buttons["companion.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertTrue(app.buttons["Authorize chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Living Room"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Mac Companion live channel"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["companion.close"].click()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }
    #endif
    #if os(iOS)
    @MainActor func testHomeIsUsableWhileStartupIsLoading() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_HOME_FIXTURE"] = "loading"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Downloads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["home.skeleton"].exists)
        XCTAssertTrue(app.staticTexts["Your live lineup"].exists)
        XCTAssertFalse(app.staticTexts["Loading your library…"].exists)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        capture("Home with stream placeholders")
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["Sign in with Twitch"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["home.skeleton"].exists)
    }
    @MainActor func testOfflineHomeOpensDownloadsDuringStartup() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_HOME_FIXTURE"] = "offline"
        app.launch()
        let downloads = app.buttons["home.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You’re offline"].exists)
        XCTAssertFalse(app.otherElements["home.skeleton"].exists)
        XCTAssertFalse(app.buttons["Sign in with Twitch"].exists)
        capture("Offline Home")
        downloads.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }
    @MainActor func testCompanionWaitingAndDismissal() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_COMPANION_FIXTURE"] = "idle"
        app.launch()
        let button = app.buttons["companion.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        XCTAssertTrue(app.staticTexts["Start a stream on your TV"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["chat.input"].firstMatch.exists)
        capture("Companion waiting for Apple TV")
        app.buttons["companion.close"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }
    @MainActor func testCompanionLiveChatFillsScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_COMPANION_FIXTURE"] = "live"
        app.launch()
        let button = app.buttons["companion.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Living Room"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        XCTAssertFalse(app.otherElements["watch.video"].isHittable)
        input.tap(); input.typeText("Hello from my iPhone")
        XCTAssertEqual(input.value as? String, "Hello from my iPhone")
        capture("Full screen companion chat with keyboard")
        app.buttons["companion.close"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }
    @MainActor func testOfflineDownloadUsesTheNormalPlayerAndOfflineChat() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launchEnvironment["TWITCHY_UI_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["TWITCHY_UI_OFFLINE_FIXTURE"] = "1"
        let before = try metrics()
        app.launch()
        let downloads = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 15)); downloads.tap()
        let play = app.buttons["download.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); play.tap()
        let video = app.otherElements["watch.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value BEGINSWITH 'playing|'"), evaluatedWith: video)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Chat could not be loaded because we are offline."].exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        if !app.buttons["watch.fullscreen"].isHittable { video.tap() }
        XCTAssertTrue(app.buttons["watch.fullscreen"].waitForExistence(timeout: 5))
        app.buttons["watch.fullscreen"].tap()
        app.buttons["watch.close"].tap()
        XCTAssertTrue(app.staticTexts["Chat could not be loaded because we are offline."].waitForExistence(timeout: 5))
        XCTAssertEqual(try metrics()["session_requests"], before["session_requests"])
        capture("Offline playback in normal player")
    }
    @MainActor func testChannelSortingAndDownloadsEmptyState() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launch()
        let options = app.buttons["channel.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["Most viewed"].tap()
        XCTAssertTrue(app.staticTexts["channel.sortLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["channel.sortLabel"].label, "Most viewed")
        app.buttons["Clips"].tap()
        XCTAssertEqual(app.staticTexts["channel.sortLabel"].label, "Most viewed")
        options.tap()
        app.buttons["Most recent"].tap()
        XCTAssertEqual(app.staticTexts["channel.sortLabel"].label, "Most recent · Last 30 days")
        capture("Channel sorting")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Take a video with you")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.count, 0, "Downloads are started from content menus, never a manual ID form")
        capture("Downloads empty state")
    }
    @MainActor func testNativeSearchTitleSurvivesChannelReturn() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launchEnvironment["TWITCHY_UI_SEARCH_FIXTURE"] = "1"
        app.launch()
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()
        let field = app.searchFields["Search Twitch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        let title = app.navigationBars.staticTexts["Search"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.maxY, field.frame.minY)
        capture("Native iPhone search")
        field.tap(); field.typeText("fixture")
        let channel = app.buttons.containing(.staticText, identifier: "Playback test").firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        channel.tap()
        XCTAssertTrue(app.buttons["channel.watchLive"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        expectation(for: NSPredicate(format: "value == %@", "fixture"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.maxY, field.frame.minY)
        capture("Native search after channel return")
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(field.exists, "Search must stay scoped to the Search tab")
        searchTab.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.maxY, field.frame.minY)
    }
    @MainActor func testPlaybackOptionsOfferDownloadsOnlyForRecordedContent() {
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launch()
        let live = app.buttons["channel.watchLive"]
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        live.tap()
        let options = app.buttons["watch.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        XCTAssertFalse(app.buttons["Download"].exists, "Live streams must not offer Download")
        XCTAssertFalse(app.buttons["Follow"].exists)
        XCTAssertFalse(app.buttons["Unfollow"].exists)
        app.buttons["View channel"].tap()
        let video = app.buttons.containing(.staticText, identifier: "Building something together").firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5), "Past streams must offer Download")
        app.buttons["View channel"].tap()
        XCTAssertTrue(app.buttons["nowPlaying.open"].waitForExistence(timeout: 5))
        capture("Channel after recorded playback")
        app.buttons["Clips"].tap()
        let clip = app.buttons.containing(.staticText, identifier: "That was close!").firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        clip.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 5), "Clips must offer Download")
        capture("Recorded-content options")
    }
    private func metrics() throws -> [String: Int] {
        let data = try Data(contentsOf: URL(string: "http://localhost:8181/__test__/metrics")!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
    @MainActor private func playbackKey(_ video: XCUIElement) -> String {
        let value = video.value as? String ?? ""
        return value.split(separator: "|").dropFirst().prefix(3).joined(separator: "|")
    }
    @MainActor private func waitForPlaying(_ video: XCUIElement) {
        expectation(for: NSPredicate(format: "value BEGINSWITH 'playing|'"), evaluatedWith: video)
        waitForExpectations(timeout: 25)
    }
    @MainActor private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testPlaybackSurvivesFullscreenChannelMiniPlayerAndBackground() throws {
        let before = try metrics()
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launch()
        let watch = app.buttons["channel.watchLive"]
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["channel.tab.broadcasts"].exists)
        capture("iPhone channel page")
        XCTAssertEqual(try metrics()["session_requests"], before["session_requests"], "Opening a channel must not start playback, even with autoplay enabled")
        watch.tap()
        let video = app.otherElements["watch.video"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        waitForPlaying(video)
        let key = playbackKey(video)
        XCTAssertFalse(key.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["luna:"].exists)
        capture("iPhone watch and inline chat")
        let composer = app.descendants(matching: .any)["chat.input"].firstMatch
        composer.tap(); composer.typeText("Layout check")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("iPhone chat with keyboard")
        app.staticTexts["luna:"].firstMatch.tap()
        expectation(for: NSPredicate { _, _ in !app.keyboards.firstMatch.exists }, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        video.tap()
        expectation(for: NSPredicate { _, _ in !app.keyboards.firstMatch.exists }, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(playbackKey(video), key)
        if !app.buttons["watch.fullscreen"].isHittable { video.tap() }
        app.buttons["watch.fullscreen"].tap()
        let exit = app.buttons["watch.exitFullscreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertEqual(playbackKey(video), key)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in video.frame.width > video.frame.height }, evaluatedWith: video)
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        capture("iPhone landscape fullscreen")
        if !exit.isHittable { video.tap() }
        exit.tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["watch.options"].waitForExistence(timeout: 5))
        app.buttons["watch.details"].tap()
        app.buttons["watch.chat"].tap()
        XCTAssertEqual(playbackKey(video), key)
        app.buttons["watch.options"].tap()
        app.buttons["View channel"].tap()
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nowPlaying.open"].exists)
        XCTAssertEqual(playbackKey(video), key)
        watch.tap()
        XCTAssertTrue(app.buttons["watch.options"].waitForExistence(timeout: 5))
        XCTAssertEqual(playbackKey(video), key, "Opening the same stream must preserve AVPlayerItem and session")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.1, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["nowPlaying.open"].waitForExistence(timeout: 5))
        app.buttons["nowPlaying.open"].tap()
        XCTAssertTrue(app.buttons["watch.options"].waitForExistence(timeout: 5))
        XCTAssertEqual(playbackKey(video), key)
        let beforePiP = (video.value as? String ?? "").components(separatedBy: "|")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        capture("iPhone automatic background PiP")
        app.activate()
        XCTAssertTrue(app.buttons["watch.options"].waitForExistence(timeout: 5))
        XCTAssertEqual(playbackKey(video), key, "Background/PiP transitions must not recreate playback")
        let afterPiP = (video.value as? String ?? "").components(separatedBy: "|")
        print("PiP capabilities before background:", beforePiP.suffix(3))
        print("PiP capabilities after background:", afterPiP.suffix(3))
        if beforePiP.count >= 8, beforePiP[7] == "supported", afterPiP.count >= 8 {
            XCTAssertEqual(beforePiP[6], "possible", "The mounted video layer must be eligible for automatic PiP")
            XCTAssertGreaterThan(Int(afterPiP[5]) ?? 0, Int(beforePiP[5]) ?? 0, "Eligible background playback must enter actual AVKit PiP")
        }
        let after = try metrics()
        XCTAssertEqual(after["session_creations"], (before["session_creations"] ?? 0) + 1)
        XCTAssertEqual(after["session_deletions"], before["session_deletions"], "Presentation changes must not DELETE the session")
        if !app.buttons["watch.close"].isHittable { video.tap() }
        app.buttons["watch.close"].tap()
        app.buttons["nowPlaying.stop"].tap()
    }
    @MainActor func testTransientStartupFailureRecoversWithoutUserRetry() throws {
        let before = try metrics()
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_SCENARIO"] = "transient-" + UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["channel.watchLive"].waitForExistence(timeout: 10))
        app.buttons["channel.watchLive"].tap()
        let video = app.otherElements["watch.video"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        waitForPlaying(video)
        let after = try metrics()
        XCTAssertEqual(after["session_requests"], (before["session_requests"] ?? 0) + 2)
        XCTAssertEqual(after["session_creations"], (before["session_creations"] ?? 0) + 1)
        if !app.buttons["watch.close"].isHittable { video.tap() }
        app.buttons["watch.close"].tap(); app.buttons["nowPlaying.stop"].tap()
    }
    @MainActor func testVODSeekingKeepsItsItemAndSession() throws {
        let before = try metrics()
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launch()
        let title = app.staticTexts["Building something together"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let video = app.otherElements["watch.video"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10)); waitForPlaying(video)
        let key = playbackKey(video)
        if !app.sliders["watch.position"].isHittable { video.tap() }
        let slider = app.sliders["watch.position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let elapsed = app.staticTexts["watch.elapsed"]
        expectation(for: NSPredicate { _, _ in
            let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 && parts[0] * 60 + parts[1] >= 14
        }, evaluatedWith: elapsed)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(playbackKey(video), key)
        if !app.buttons["watch.forward"].isHittable { video.tap() }
        app.buttons["watch.forward"].tap()
        expectation(for: NSPredicate { _, _ in
            let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 && parts[0] * 60 + parts[1] >= 24
        }, evaluatedWith: elapsed)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(playbackKey(video), key)
        let after = try metrics()
        XCTAssertEqual(after["session_creations"], (before["session_creations"] ?? 0) + 1)
        XCTAssertEqual(after["session_deletions"], before["session_deletions"])
        capture("iPhone VOD controls")
        if !app.buttons["watch.close"].isHittable { video.tap() }
        app.buttons["watch.close"].tap(); app.buttons["nowPlaying.stop"].tap()
    }
    @MainActor func testUnavailableStreamDoesNotLoopOrStartInvalidHLS() throws {
        let before = try metrics()
        let app = XCUIApplication()
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_FIXTURE"] = "1"
        app.launchEnvironment["TWITCHY_UI_PLAYBACK_SCENARIO"] = "unavailable"
        app.launch()
        XCTAssertTrue(app.buttons["channel.watchLive"].waitForExistence(timeout: 10))
        app.buttons["channel.watchLive"].tap()
        XCTAssertTrue(app.staticTexts["Stream unavailable"].waitForExistence(timeout: 10))
        let video = app.otherElements["watch.video"].firstMatch
        XCTAssertTrue((video.value as? String ?? "").contains("|none|"))
        Thread.sleep(forTimeInterval: 3)
        let after = try metrics()
        XCTAssertEqual(after["session_requests"], (before["session_requests"] ?? 0) + 1)
        XCTAssertEqual(after["session_creations"], before["session_creations"])
        capture("iPhone unavailable stream")
        app.buttons["watch.close"].tap(); app.buttons["nowPlaying.stop"].tap()
    }
    #endif
}
