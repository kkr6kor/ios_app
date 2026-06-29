import SwiftUI

// ── Garage ──────────────────────────────────────────────────────────────────
struct GarageView: View {
    @EnvironmentObject var data: AppData
    @State private var showAdd = false
    @State private var editing: Vehicle?

    private var activeOdometer: Double { data.vehicles.map(\.odometerKm).max() ?? 0 }

    var body: some View {
        NavigationStack {
            List {
                Section("Vehicles") {
                    ForEach(data.vehicles) { v in
                        Button { editing = v } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(v.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(Int(v.odometerKm)) km").foregroundStyle(.secondary)
                                }
                                ComplianceLabel(kind: "PUC", date: v.pucExpiry)
                                ComplianceLabel(kind: "Insurance", date: v.insuranceExpiry)
                            }
                        }
                    }
                }
                Section("Maintenance log") {
                    if data.maintenance.isEmpty {
                        Text("No entries yet.").foregroundStyle(.secondary)
                    }
                    ForEach(data.maintenance.sorted { $0.date > $1.date }) { m in
                        VStack(alignment: .leading) {
                            Text(m.item)
                            Text("\(Int(m.odometerKm)) km · \(m.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let interval = m.intervalKm {
                                let due = m.odometerKm + interval
                                let overdue = activeOdometer >= due
                                Text(overdue ? "⚠️ Service due (was \(Int(due)) km)" : "Next at \(Int(due)) km")
                                    .font(.caption2).foregroundStyle(overdue ? .orange : .secondary)
                            }
                            if !m.notes.isEmpty { Text(m.notes).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { idx in
                        let sorted = data.maintenance.sorted { $0.date > $1.date }
                        idx.map { sorted[$0].id }.forEach { id in data.maintenance.removeAll { $0.id == id } }
                    }
                }
            }
            .navigationTitle("Garage")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showAdd) { AddMaintenanceSheet() }
            .sheet(item: $editing) { v in VehicleEditSheet(vehicle: v) }
        }
    }
}

struct ComplianceLabel: View {
    let kind: String
    let date: Date?
    var body: some View {
        if let date {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            let color: Color = days < 0 ? .red : (days <= 14 ? .orange : .secondary)
            Text("\(kind): \(date.formatted(date: .abbreviated, time: .omitted))"
                 + (days < 0 ? " (expired)" : days <= 14 ? " (\(days)d)" : ""))
                .font(.caption2).foregroundStyle(color)
        }
    }
}

struct VehicleEditSheet: View {
    @EnvironmentObject var data: AppData
    @Environment(\.dismiss) private var dismiss
    @State var vehicle: Vehicle
    @State private var odo: String
    @State private var hasPUC: Bool
    @State private var hasIns: Bool

    init(vehicle: Vehicle) {
        _vehicle = State(initialValue: vehicle)
        _odo = State(initialValue: String(Int(vehicle.odometerKm)))
        _hasPUC = State(initialValue: vehicle.pucExpiry != nil)
        _hasIns = State(initialValue: vehicle.insuranceExpiry != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $vehicle.name)
                TextField("Odometer (km)", text: $odo).keyboardType(.numberPad)
                Toggle("Track PUC expiry", isOn: $hasPUC)
                if hasPUC {
                    DatePicker("PUC expires", selection: Binding(
                        get: { vehicle.pucExpiry ?? Date() },
                        set: { vehicle.pucExpiry = $0 }), displayedComponents: .date)
                }
                Toggle("Track insurance expiry", isOn: $hasIns)
                if hasIns {
                    DatePicker("Insurance expires", selection: Binding(
                        get: { vehicle.insuranceExpiry ?? Date() },
                        set: { vehicle.insuranceExpiry = $0 }), displayedComponents: .date)
                }
            }
            .navigationTitle(vehicle.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vehicle.odometerKm = Double(odo) ?? vehicle.odometerKm
                        if !hasPUC { vehicle.pucExpiry = nil }
                        if !hasIns { vehicle.insuranceExpiry = nil }
                        data.updateVehicle(vehicle)
                        ReminderService.shared.reschedule(vehicles: data.vehicles)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AddMaintenanceSheet: View {
    @EnvironmentObject var data: AppData
    @Environment(\.dismiss) private var dismiss
    @State private var item = "Chain lube"
    @State private var odo = ""
    @State private var notes = ""
    @State private var hasInterval = false
    @State private var interval = "5000"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item (e.g. Oil change)", text: $item)
                TextField("Odometer (km)", text: $odo).keyboardType(.numberPad)
                TextField("Notes", text: $notes)
                Toggle("Repeat at interval", isOn: $hasInterval)
                if hasInterval {
                    TextField("Interval (km)", text: $interval).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Log maintenance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        data.maintenance.append(MaintenanceLog(
                            item: item, odometerKm: Double(odo) ?? 0, notes: notes,
                            intervalKm: hasInterval ? Double(interval) : nil))
                        dismiss()
                    }.disabled(item.isEmpty)
                }
            }
        }
    }
}

// ── Fuel ────────────────────────────────────────────────────────────────────
struct FuelView: View {
    @EnvironmentObject var data: AppData
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if let latest = data.mileages().first {
                    Section("Latest mileage") {
                        Text(String(format: "%.1f km/l", latest.kmPerL)).font(.title2.bold())
                    }
                }
                Section("Fill-ups") {
                    if data.fuel.isEmpty { Text("No fill-ups yet.").foregroundStyle(.secondary) }
                    ForEach(data.fuel.sorted { $0.date > $1.date }) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(String(format: "%.2f L", f.liters))
                                Text("\(Int(f.odometerKm)) km · \(f.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "₹%.0f", f.cost)).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let sorted = data.fuel.sorted { $0.date > $1.date }
                        idx.map { sorted[$0].id }.forEach { id in data.fuel.removeAll { $0.id == id } }
                    }
                }
            }
            .navigationTitle("Fuel")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showAdd) { AddFuelSheet() }
        }
    }
}

struct AddFuelSheet: View {
    @EnvironmentObject var data: AppData
    @Environment(\.dismiss) private var dismiss
    @State private var liters = ""
    @State private var cost = ""
    @State private var odo = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Litres", text: $liters).keyboardType(.decimalPad)
                TextField("Cost", text: $cost).keyboardType(.decimalPad)
                TextField("Odometer (km)", text: $odo).keyboardType(.numberPad)
            }
            .navigationTitle("Add fill-up")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        data.fuel.append(FuelEntry(liters: Double(liters) ?? 0,
                                                   cost: Double(cost) ?? 0,
                                                   odometerKm: Double(odo) ?? 0))
                        dismiss()
                    }.disabled(liters.isEmpty || odo.isEmpty)
                }
            }
        }
    }
}

// ── Rides ───────────────────────────────────────────────────────────────────
struct RidesView: View {
    @EnvironmentObject var data: AppData
    var body: some View {
        NavigationStack {
            List {
                if data.rides.isEmpty {
                    Text("Rides are recorded automatically during navigation (Phase 3).")
                        .foregroundStyle(.secondary)
                }
                ForEach(data.rides.sorted { $0.date > $1.date }) { r in
                    VStack(alignment: .leading) {
                        Text(String(format: "%.1f km · %.0f min", r.distanceKm, r.durationMin))
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Rides")
        }
    }
}

// ── Settings ────────────────────────────────────────────────────────────────
struct SettingsView: View {
    @EnvironmentObject var data: AppData
    var body: some View {
        NavigationStack {
            Form {
                Section("Reminders") {
                    Button("Enable expiry reminders") {
                        ReminderService.shared.requestAuthorization()
                        ReminderService.shared.reschedule(vehicles: data.vehicles)
                    }
                    Text("Get notified 7 days before PUC / insurance expiry (set the dates per vehicle in Garage).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("App", value: "Cairn")
                    LabeledContent("Bundle", value: "com.cairn.dash")
                    LabeledContent("Dash", value: "RE Tripper (Himalayan/Guerrilla 450)")
                }
                Section("Connectivity (free Apple team)") {
                    Text("Control plane uses unicast to 192.168.1.1:2000. Auto Wi-Fi join and "
                         + "broadcast need the paid Apple Developer Program (Hotspot + Multicast entitlements).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Roadmap") {
                    Text("Navigation (OSRM + turn-by-turn), live map projection, voice guidance, "
                         + "expenses, and Firebase sync are the next phases.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
