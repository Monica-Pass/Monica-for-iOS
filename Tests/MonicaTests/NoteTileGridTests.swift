import XCTest
@testable import Monica

final class NoteTileGridTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ru.takagi.monica.tests.note-layout.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testLayoutDefaultsToListWhenNothingIsStored() {
        XCTAssertEqual(UserDefaultsNoteListLayoutStore(defaults: defaults).loadLayout(), .list)
    }

    func testLayoutChoiceSurvivesANewStoreInstance() {
        let store = UserDefaultsNoteListLayoutStore(defaults: defaults)

        store.saveLayout(.grid)
        XCTAssertEqual(defaults.string(forKey: AppNoteListLayout.userDefaultsKey), "grid")
        XCTAssertEqual(UserDefaultsNoteListLayoutStore(defaults: defaults).loadLayout(), .grid)

        store.saveLayout(.list)
        XCTAssertEqual(UserDefaultsNoteListLayoutStore(defaults: defaults).loadLayout(), .list)
    }

    func testAllLayoutsRoundTripThroughUserDefaults() {
        let store = UserDefaultsNoteListLayoutStore(defaults: defaults)

        for layout in AppNoteListLayout.allCases {
            store.saveLayout(layout)
            XCTAssertEqual(UserDefaultsNoteListLayoutStore(defaults: defaults).loadLayout(), layout)
        }
    }

    func testInvalidPersistedValueFallsBackToList() {
        let store = UserDefaultsNoteListLayoutStore(defaults: defaults)

        for invalid in ["masonry", "", "   ", "tile-grid", "0"] {
            defaults.set(invalid, forKey: AppNoteListLayout.userDefaultsKey)
            XCTAssertEqual(store.loadLayout(), .list, "非法值 \(invalid) 应回退到列表")
        }
    }

    func testPersistedValueIsTrimmedAndCaseInsensitive() {
        defaults.set("  GRID  ", forKey: AppNoteListLayout.userDefaultsKey)
        XCTAssertEqual(UserDefaultsNoteListLayoutStore(defaults: defaults).loadLayout(), .grid)
    }

    func testLayoutUserDefaultsKeyIsStable() {
        // 键值属于跨版本约定，改名会让已选瓷砖的用户被重置回列表。
        XCTAssertEqual(AppNoteListLayout.userDefaultsKey, "monica.notes.layout")
    }
}
