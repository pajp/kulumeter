import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationStack {
            List {
                accountSection
                importSection
                ridesSection
                statusSection
            }
            .navigationTitle("Kulumeter")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.uploadSelectedRides() }
                    } label: {
                        Label("Upload", systemImage: "arrow.up.circle")
                    }
                    .disabled(!viewModel.canUpload)
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            TextField("Username", text: $viewModel.settings.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)

            Toggle("Mark uploads as e-bike", isOn: $viewModel.settings.defaultElectric)

            if let contestID = viewModel.discoveredContestID {
                LabeledContent("Contest ID", value: contestID)
            }
        } header: {
            Text("Kilometrikisa")
        } footer: {
            Text("The password is stored in the iOS Keychain. The active contest ID is discovered from Kilometrikisa when uploading.")
        }
    }

    private var importSection: some View {
        Section {
            DatePicker("From", selection: $viewModel.startDate, displayedComponents: .date)
            DatePicker("To", selection: $viewModel.endDate, displayedComponents: .date)

            Button {
                Task { await viewModel.importRides() }
            } label: {
                Label("Import Cycling Workouts", systemImage: "heart.text.square")
            }
            .disabled(viewModel.state.isWorking)
        } header: {
            Text("Apple Health")
        }
    }

    private var ridesSection: some View {
        Section {
            if viewModel.rides.isEmpty {
                ContentUnavailableView(
                    "No Imported Rides",
                    systemImage: "bicycle",
                    description: Text("Import cycling workouts from Apple Health to preview daily totals.")
                )
            } else {
                ForEach(viewModel.rides) { ride in
                    Button {
                        viewModel.toggleSelection(for: ride)
                    } label: {
                        RideRow(
                            ride: ride,
                            isSelected: viewModel.selectedRideIDs.contains(ride.id),
                            isLogged: viewModel.loggedRideIDs.contains(ride.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Preview")
        } footer: {
            if !viewModel.selectedRideIDs.isEmpty {
                Text("\(viewModel.selectedRideIDs.count) day\(viewModel.selectedRideIDs.count == 1 ? "" : "s") selected, \(viewModel.totalDistance, specifier: "%.2f") km total.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .importing:
            Section {
                ProgressView("Reading Apple Health")
            }
        case .loggingIn:
            Section {
                ProgressView("Logging in to Kilometrikisa")
            }
        case .discoveringContest:
            Section {
                ProgressView("Finding active Kilometrikisa contest")
            }
        case .checkingExistingLogs:
            Section {
                ProgressView("Checking Kilometrikisa log")
            }
        case .uploading(let current, let total):
            Section {
                ProgressView("Uploading \(current) of \(total)")
            }
        case .done(let message):
            Section {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct RideRow: View {
    let ride: DailyRide
    let isSelected: Bool
    let isLogged: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(ride.dateString)
                    .font(.headline)

                Text("\(ride.roundedDistance, specifier: "%.2f") km")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ride.hours) h \(ride.minutes) min")
                    .font(.subheadline)

                if ride.isElectric {
                    Text("E-bike")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isLogged {
                    Text("Already logged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
