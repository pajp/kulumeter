import MapKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationStack {
            List {
                accountSection
                teamSection
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

    private var teamSection: some View {
        Section {
            Button {
                Task { await viewModel.loadTeamRanking() }
            } label: {
                if case .loadingTeamRanking = viewModel.state {
                    HStack {
                        ProgressView()
                        Text("Loading Team Ranking")
                    }
                } else {
                    Label("Load My Team Ranking", systemImage: "person.3.sequence")
                }
            }
            .disabled(!viewModel.canLoadTeamRanking)

            if let ranking = viewModel.teamRanking {
                LabeledContent("Team", value: ranking.name)
                LabeledContent("Riders", value: "\(ranking.rows.count)")

                ForEach(ranking.rows) { row in
                    TeamRankingRowView(row: row)
                }
            }
        } header: {
            Text("Team Ranking")
        } footer: {
            Text("The team is discovered from your Kilometrikisa profile after login.")
        }
    }

    private var importSection: some View {
        Section {
            DatePicker("From", selection: $viewModel.startDate, displayedComponents: .date)
            DatePicker("To", selection: $viewModel.endDate, displayedComponents: .date)

            Button {
                Task { await viewModel.importRides() }
            } label: {
                if viewModel.state.isImportingHealth {
                    Label("Importing Cycling Workouts", systemImage: "hourglass")
                } else {
                    Label("Import Cycling Workouts", systemImage: "heart.text.square")
                }
            }
            .disabled(viewModel.state.isWorking)

            importProgressView
        } header: {
            Text("Apple Health")
        }
    }

    @ViewBuilder
    private var importProgressView: some View {
        switch viewModel.state {
        case .authorizingHealth:
            ProgressView("Requesting Apple Health access")
        case .loadingHealthWorkouts:
            ProgressView("Loading cycling workouts")
        case .importingHealth(let current, let total):
            ProgressView(
                value: Double(current),
                total: Double(max(total, 1))
            ) {
                Text("Reading Apple Health")
            } currentValueLabel: {
                Text("Workout \(current) of \(total)")
            }
        default:
            EmptyView()
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
        case .idle, .authorizingHealth, .loadingHealthWorkouts, .importingHealth:
            EmptyView()
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
        case .loadingTeamRanking:
            Section {
                ProgressView("Loading team ranking")
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

private struct TeamRankingRowView: View {
    let row: TeamRankingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(row.rank)")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 34, alignment: .leading)

                Text(row.name)
                    .font(.headline)

                if row.isCurrentUser {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.16), in: Capsule())
                }

                Spacer()

                Text("\(row.totalKilometers) km")
                    .font(.subheadline.monospacedDigit())
            }

            HStack {
                Label("\(row.muscleKilometers) muscle", systemImage: "bicycle")
                Spacer()
                Label("\(row.electricKilometers) e-bike", systemImage: "bolt")
                Spacer()
                Label("\(row.rideDays) days", systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(row.isCurrentUser ? Color.yellow.opacity(0.22) : nil)
    }
}

private struct RideRow: View {
    let ride: DailyRide
    let isSelected: Bool
    let isLogged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if ride.hasRoute {
                DailyRouteMap(ride: ride)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private struct DailyRouteMap: View {
    let ride: DailyRide

    var body: some View {
        Map(initialPosition: .region(ride.routeRegion)) {
            ForEach(Array(ride.routeSegments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.smoothedForDisplay.map(\.coordinate))
                    .stroke(
                        .blue,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }
}

private extension DailyRide {
    var hasRoute: Bool {
        routeSegments.contains { $0.count > 1 }
    }

    var routeRegion: MKCoordinateRegion {
        let points = routeSegments.flatMap { $0 }
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude

        for point in points.dropFirst() {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }

        let latitudeDelta = max((maxLatitude - minLatitude) * 1.35, 0.01)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.35, 0.01)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

private extension RoutePoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension Array where Element == RoutePoint {
    var smoothedForDisplay: [RoutePoint] {
        guard count > 3 else {
            return self
        }

        var points = self
        for _ in 0..<5 {
            points = points.chaikinSmoothed()
        }
        return points
    }

    private func chaikinSmoothed() -> [RoutePoint] {
        guard count > 2 else {
            return self
        }

        var result: [RoutePoint] = [self[0]]
        result.reserveCapacity((count * 2) - 1)

        for index in 0..<(count - 1) {
            let first = self[index]
            let second = self[index + 1]
            result.append(
                RoutePoint(
                    latitude: (first.latitude * 0.75) + (second.latitude * 0.25),
                    longitude: (first.longitude * 0.75) + (second.longitude * 0.25)
                )
            )
            result.append(
                RoutePoint(
                    latitude: (first.latitude * 0.25) + (second.latitude * 0.75),
                    longitude: (first.longitude * 0.25) + (second.longitude * 0.75)
                )
            )
        }

        result.append(self[count - 1])
        return result
    }
}

#Preview {
    ContentView()
}
