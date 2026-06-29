import SwiftUI
import MapKit

/// Phase 3 navigation UI: search a destination (keyless MapKit local search),
/// start guidance, and see the live instruction / ETA. Guidance renders to the dash
/// via the controller's navigation projection mode.
struct NavView: View {
    @EnvironmentObject var controller: DashController
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    HStack {
                        TextField("Search a place (e.g. Manali)", text: $query)
                            .onSubmit { search() }
                        Button("Search") { search() }.disabled(query.isEmpty)
                    }
                    if searching { ProgressView() }
                    ForEach(results, id: \.self) { item in
                        Button {
                            start(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Destination")
                                if let t = item.placemark.title {
                                    Text(t).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if controller.nav.isNavigating {
                    Section("Guidance") {
                        Text(controller.nav.instruction).font(.headline)
                        LabeledContent("To turn", value: dist(controller.nav.distanceToTurnM))
                        LabeledContent("Remaining", value: dist(controller.nav.remainingM))
                        LabeledContent("ETA", value: prettyEta(controller.nav.etaHHMM))
                    }
                    Section("Voice") {
                        Picker("Voice", selection: voiceBinding) {
                            ForEach(VoiceManager.Mode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    Section {
                        Button("Stop navigation", role: .destructive) { controller.stopNavigation() }
                    }
                }

                Section {
                    Text("Guidance shows on the dash when connected (auto-projects in navigation mode). "
                         + "The bike joystick zooms the dash map. Map tiles (MapLibre) come in a later phase — "
                         + "for now the dash shows the route line, your position, and the next turn.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Navigate")
        }
    }

    private var voiceBinding: Binding<VoiceManager.Mode> {
        Binding(get: { controller.voice.mode }, set: { controller.voice.mode = $0 })
    }

    private func search() {
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            results = response?.mapItems ?? []
        }
    }

    private func start(_ item: MKMapItem) {
        results = []
        controller.startNavigation(to: item.placemark.coordinate, name: item.name ?? "Destination")
    }

    private func dist(_ m: Int) -> String { m < 1000 ? "\(m) m" : String(format: "%.1f km", Double(m) / 1000) }
    private func prettyEta(_ s: String) -> String {
        guard s.count == 4 else { return s.isEmpty ? "—" : s }
        let i = s.index(s.startIndex, offsetBy: 2)
        return "\(s[..<i]):\(s[i...])"
    }
}
