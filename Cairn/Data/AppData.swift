import Foundation

// ── Standalone-feature models (OpenDash parity, no bike dependency) ──────────
struct Vehicle: Codable, Identifiable {
    var id = UUID()
    var name: String
    var odometerKm: Double = 0
    var pucExpiry: Date? = nil
    var insuranceExpiry: Date? = nil
}

struct MaintenanceLog: Codable, Identifiable {
    var id = UUID()
    var item: String
    var odometerKm: Double
    var date: Date = Date()
    var notes: String = ""
    var intervalKm: Double? = nil      // if set, next service due at odometerKm + intervalKm
}

struct FuelEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date = Date()
    var liters: Double
    var cost: Double
    var odometerKm: Double
}

struct Ride: Codable, Identifiable {
    var id = UUID()
    var date: Date = Date()
    var distanceKm: Double
    var durationMin: Double
}

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case fuel, repairs, accessories, gear, food, stays, transport, other
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .fuel: return "fuelpump"
        case .repairs: return "wrench.and.screwdriver"
        case .accessories: return "bag"
        case .gear: return "helmet"            // falls back to a generic glyph if unavailable
        case .food: return "fork.knife"
        case .stays: return "bed.double"
        case .transport: return "car"
        case .other: return "ellipsis.circle"
        }
    }
}

struct Expense: Codable, Identifiable {
    var id = UUID()
    var date: Date = Date()
    var category: ExpenseCategory
    var amount: Double
    var note: String = ""
}

/// Local-first store (JSON in Documents) — the GRDB/Firebase layer from the plan
/// replaces this later; for now it gives the standalone features real persistence.
final class AppData: ObservableObject {
    @Published var vehicles: [Vehicle] { didSet { save() } }
    @Published var maintenance: [MaintenanceLog] { didSet { save() } }
    @Published var fuel: [FuelEntry] { didSet { save() } }
    @Published var rides: [Ride] { didSet { save() } }
    @Published var expenses: [Expense] { didSet { save() } }

    private struct Container: Codable {
        var vehicles: [Vehicle] = []
        var maintenance: [MaintenanceLog] = []
        var fuel: [FuelEntry] = []
        var rides: [Ride] = []
        var expenses: [Expense] = []
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appdata.json")
    }

    init() {
        let c = Self.loadContainer()
        vehicles = c.vehicles
        maintenance = c.maintenance
        fuel = c.fuel
        rides = c.rides
        expenses = c.expenses
        if vehicles.isEmpty {
            vehicles = [Vehicle(name: "Himalayan 450"), Vehicle(name: "Guerrilla 450")]
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    func updateVehicle(_ v: Vehicle) {
        if let i = vehicles.firstIndex(where: { $0.id == v.id }) { vehicles[i] = v }
    }

    /// Mileage (km/l) between consecutive fill-ups, latest first.
    func mileages() -> [(date: Date, kmPerL: Double)] {
        let sorted = fuel.sorted { $0.odometerKm < $1.odometerKm }
        var out: [(Date, Double)] = []
        guard sorted.count > 1 else { return [] }
        for i in 1..<sorted.count {
            let dist = sorted[i].odometerKm - sorted[i - 1].odometerKm
            if dist > 0, sorted[i].liters > 0 { out.append((sorted[i].date, dist / sorted[i].liters)) }
        }
        return out.reversed()
    }

    /// Expenses, optionally limited to the current calendar month.
    func expenseList(thisMonthOnly: Bool) -> [Expense] {
        guard thisMonthOnly else { return expenses.sorted { $0.date > $1.date } }
        let cal = Calendar.current
        return expenses
            .filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .sorted { $0.date > $1.date }
    }

    func expenseTotal(thisMonthOnly: Bool) -> Double {
        expenseList(thisMonthOnly: thisMonthOnly).reduce(0) { $0 + $1.amount }
    }

    func expenseByCategory(thisMonthOnly: Bool) -> [(ExpenseCategory, Double)] {
        let list = expenseList(thisMonthOnly: thisMonthOnly)
        return ExpenseCategory.allCases.compactMap { cat in
            let total = list.filter { $0.category == cat }.reduce(0) { $0 + $1.amount }
            return total > 0 ? (cat, total) : nil
        }
    }

    private func save() {
        let c = Container(vehicles: vehicles, maintenance: maintenance, fuel: fuel, rides: rides, expenses: expenses)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: Self.url) }
    }

    private static func loadContainer() -> Container {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Container.self, from: data) else { return Container() }
        return c
    }
}
