import XCTest
import SwiftData
@testable import Envelope

@MainActor
final class BudgetPaletteTests: XCTestCase {
    func testProgressDrainsWithWhatsLeft() {
        XCTAssertEqual(BudgetPalette.fill(leftCents: 300_000, monthlyCents: 300_000), 1)
        XCTAssertEqual(BudgetPalette.fill(leftCents: 150_000, monthlyCents: 300_000), 0.5)
        XCTAssertEqual(BudgetPalette.fill(leftCents: 0, monthlyCents: 300_000), 0)
        XCTAssertEqual(BudgetPalette.fill(leftCents: -5_000, monthlyCents: 300_000), 0, "over budget is empty")
        XCTAssertEqual(BudgetPalette.fill(leftCents: 400_000, monthlyCents: 300_000), 1, "never more than full")
        XCTAssertEqual(BudgetPalette.fill(leftCents: 100, monthlyCents: 0), 0)
    }

    func testColours() {
        XCTAssertEqual(BudgetPalette.resolvedKey(colorName: "pink", sortOrder: 0), "pink")
        XCTAssertEqual(BudgetPalette.resolvedKey(colorName: "", sortOrder: 0), "blue")
        XCTAssertEqual(BudgetPalette.resolvedKey(colorName: "", sortOrder: 1), "green")
        XCTAssertEqual(BudgetPalette.resolvedKey(colorName: "not-a-colour", sortOrder: 2), "orange")
        XCTAssertEqual(BudgetPalette.resolvedKey(colorName: "", sortOrder: BudgetPalette.keys.count), "blue", "wraps around")
        XCTAssertEqual(Set(BudgetPalette.keys).count, BudgetPalette.keys.count)
    }

    func testReordering() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 1, in: context)
        let fuel = try BudgetService.addBudget(name: "Fuel", monthlyCents: 1, in: context)
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 1, in: context)
        func order() throws -> [String] { try BudgetService.activeBudgets(in: context).map(\.name) }

        let funColour = BudgetPalette.key(for: fun)
        try BudgetService.move(fun, onto: food, in: context)
        XCTAssertEqual(try order(), ["Fun", "Food", "Fuel"])
        XCTAssertEqual(BudgetPalette.key(for: fun), funColour, "an automatic colour stays with the budget when it moves")

        try BudgetService.move(fun, onto: fuel, in: context)
        XCTAssertEqual(try order(), ["Food", "Fuel", "Fun"])

        try BudgetService.move(fuel, by: -1, in: context)
        XCTAssertEqual(try order(), ["Fuel", "Food", "Fun"])
        try BudgetService.move(fuel, by: -1, in: context)
        XCTAssertEqual(try order(), ["Fuel", "Food", "Fun"], "already first")
        try BudgetService.move(food, by: 1, in: context)
        XCTAssertEqual(try order(), ["Fuel", "Fun", "Food"])

        // List drag in Reorder mode (SwiftUI onMove offsets).
        try BudgetService.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, in: context)
        XCTAssertEqual(try order(), ["Food", "Fuel", "Fun"])
        try BudgetService.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, in: context)
        XCTAssertEqual(try order(), ["Fuel", "Fun", "Food"])
        try BudgetService.move(fromOffsets: IndexSet([0, 1]), toOffset: 3, in: context)
        XCTAssertEqual(try order(), ["Food", "Fuel", "Fun"])
    }
}
