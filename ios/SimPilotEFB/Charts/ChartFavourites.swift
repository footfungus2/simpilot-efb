import Foundation

/// A chart named without its pages: enough to find it again at its airport.
struct ChartRef: Codable, Identifiable, Equatable {
    var icao: String
    var guid: String
    var name: String
    var type: String

    var id: String { guid }
}

/// Charts you starred and the ones you opened last, across airports. Kept on the iPad (UserDefaults).
@MainActor
final class ChartFavourites: ObservableObject {
    static let recentLimit = 12

    @Published private(set) var favourites: [ChartRef]
    @Published private(set) var recents: [ChartRef]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favourites = Self.load("chartFavourites", defaults)
        recents = Self.load("chartRecents", defaults)
    }

    private static func load(_ key: String, _ defaults: UserDefaults) -> [ChartRef] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ChartRef].self, from: $0) } ?? []
    }

    private func save(_ list: [ChartRef], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    func isFavourite(_ guid: String) -> Bool { favourites.contains { $0.guid == guid } }

    func ref(_ guid: String) -> ChartRef? { favourites.first { $0.guid == guid } ?? recents.first { $0.guid == guid } }

    func toggle(_ ref: ChartRef) {
        if let i = favourites.firstIndex(where: { $0.guid == ref.guid }) { favourites.remove(at: i) } else { favourites.append(ref) }
        save(favourites, "chartFavourites")
    }

    /// Puts the chart first in the recent list (once, whatever airport it is at).
    func recordOpen(_ ref: ChartRef) {
        guard recents.first != ref else { return }
        recents.removeAll { $0.guid == ref.guid }
        recents.insert(ref, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        save(recents, "chartRecents")
    }

    func clearRecents() {
        recents = []
        save(recents, "chartRecents")
    }
}
