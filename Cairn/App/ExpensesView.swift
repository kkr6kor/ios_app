import SwiftUI

struct ExpensesView: View {
    @EnvironmentObject var data: AppData
    @State private var thisMonth = true
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $thisMonth) {
                        Text("This month").tag(true)
                        Text("All time").tag(false)
                    }.pickerStyle(.segmented)
                    LabeledContent("Total", value: money(data.expenseTotal(thisMonthOnly: thisMonth)))
                        .font(.headline)
                }

                let byCat = data.expenseByCategory(thisMonthOnly: thisMonth)
                if !byCat.isEmpty {
                    Section("By category") {
                        ForEach(byCat, id: \.0) { cat, total in
                            HStack {
                                Label(cat.label, systemImage: cat.symbol)
                                Spacer()
                                Text(money(total)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Entries") {
                    let list = data.expenseList(thisMonthOnly: thisMonth)
                    if list.isEmpty { Text("No expenses yet.").foregroundStyle(.secondary) }
                    ForEach(list) { e in
                        HStack {
                            Label(e.category.label, systemImage: e.category.symbol)
                            VStack(alignment: .leading) {
                                if !e.note.isEmpty { Text(e.note) }
                                Text(e.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(e.amount))
                        }
                    }
                    .onDelete { idx in
                        let list = data.expenseList(thisMonthOnly: thisMonth)
                        idx.map { list[$0].id }.forEach { id in data.expenses.removeAll { $0.id == id } }
                    }
                }
            }
            .navigationTitle("Expenses")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showAdd) { AddExpenseSheet() }
        }
    }

    private func money(_ v: Double) -> String { String(format: "₹%.0f", v) }
}

struct AddExpenseSheet: View {
    @EnvironmentObject var data: AppData
    @Environment(\.dismiss) private var dismiss
    @State private var category: ExpenseCategory = .fuel
    @State private var amount = ""
    @State private var note = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(ExpenseCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                TextField("Note", text: $note)
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Add expense")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        data.expenses.append(Expense(date: date, category: category,
                                                     amount: Double(amount) ?? 0, note: note))
                        dismiss()
                    }.disabled(amount.isEmpty)
                }
            }
        }
    }
}
