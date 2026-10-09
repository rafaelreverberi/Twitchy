import XCTest
final class NavigationTests: XCTestCase {
    @MainActor private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
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
            } else {
                let showSidebar = app.buttons["Show Sidebar"]
                if showSidebar.exists { activate(showSidebar) }
                XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "Missing destination \(name)")
            }
            #endif
        }
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Twitchy primary navigation"; capture.lifetime = .keepAlways; add(capture)
        activate(app.buttons["settings.open"])
        XCTAssertTrue(app.textFields["oauth.clientID"].waitForExistence(timeout: 5))
    }
}
