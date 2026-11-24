import AppKit
import Combine
import EventKit

struct WeatherLocation: Codable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let admin1: String?
    let country: String?

    var label: String {
        [name, admin1, country].compactMap { $0 }.reduce(into: [String]()) { parts, name in
            if !parts.contains(name) { parts.append(name) }
        }.joined(separator: " · ")
    }
}

struct LocalTask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var done = false
}

struct WeatherReading: Codable {
    struct Hour: Codable, Identifiable {
        var id: Date { time }
        let time: Date
        let temperature: Double?
        let code: Int?
        let precipitation: Int?
        var isDay: Bool?
    }

    let city: String
    let temperature: Double
    let feelsLike: Double
    let recorded: Date
    var code: Int?
    var isDay: Bool?
    var humidity: Int?
    var wind: Double?
    var timezone: String?
    var hourly: [Hour]?
    var location: WeatherLocation?
}

struct CalendarEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    var link: URL?

    func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && (end > interval.start || interval.contains(start))
    }
}

struct MeetingAlert {
    struct JoinKey: Hashable {
        let id: String
        let start: Date
        let link: URL
    }

    static let leadTime: TimeInterval = 300

    let entry: CalendarEntry
    let link: URL
    var joinKey: JoinKey { JoinKey(id: entry.id, start: entry.start, link: link) }
    var appears: Date { entry.start.addingTimeInterval(-Self.leadTime) }
    var expires: Date { min(entry.end, entry.start.addingTimeInterval(Self.leadTime)) }
    var menuTitle: String {
        entry.start.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU"))) + " · " + entry.title
    }

    init?(_ entry: CalendarEntry) {
        guard !entry.allDay, entry.end > entry.start, let link = entry.link else { return nil }
        self.entry = entry
        self.link = link
    }

    static func plan(for entries: [CalendarEntry], at now: Date, excluding joined: Set<JoinKey>)
        -> (current: [MeetingAlert], nextChange: Date?) {
        let alerts = entries.compactMap(MeetingAlert.init).filter {
            $0.expires > now && !joined.contains($0.joinKey)
        }.sorted { left, right in
            if left.entry.start != right.entry.start { return left.entry.start < right.entry.start }
            return left.entry.id < right.entry.id
        }
        let current = alerts.prefix { $0.appears <= now }
        let nextChange = alerts.map { $0.appears > now ? $0.appears : $0.expires }.min()
        return (Array(current), nextChange)
    }
}

final class CalendarFeed: ObservableObject {
    enum Access { case undecided, denied, available }

    @Published private(set) var access: Access = .undecided
    @Published private(set) var entries: [CalendarEntry] = []
    var onAccessRequested: (() -> Void)?
    private lazy var store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func load(_ interval: DateInterval) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .available
        case .notDetermined: access = .undecided
        default: access = .denied
        }
        guard access == .available else {
            entries = []
            return
        }
        entries = events(in: interval)
    }

    func events(in interval: DateInterval) -> [CalendarEntry] {
        guard hasAccess else { return [] }
        let query = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: query).map { event in
            return CalendarEntry(id: (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + String(event.startDate.timeIntervalSinceReferenceDate),
                          title: event.title ?? "Событие", start: event.startDate,
                          end: event.endDate, allDay: event.isAllDay, link: Self.meetingLink(for: event))
        }.sorted { $0.start < $1.start }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func meetingLink(for event: EKEvent) -> URL? {
        func web(_ url: URL?) -> URL? {
            guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return url
        }
        func conference(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com",
                    "telemost.yandex.ru", "whereby.com", "facetime.apple.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }
        let direct = [web(event.url), web(event.location.flatMap(URL.init(string:)))].compactMap { $0 }
        if let link = direct.first(where: conference) { return link }
        let details = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let embedded = linkDetector?.matches(in: details, range: NSRange(details.startIndex..., in: details))
            .compactMap { web($0.url) }.first(where: conference)
        return embedded ?? direct.first
    }

    @MainActor func request() async {
        _ = try? await store.requestFullAccessToEvents()
        onAccessRequested?()
    }
}

enum WeatherPreview {
    private struct Locations: Decodable {
        var results: [WeatherLocation]?
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let weatherCode: Int?
            let isDay: Int?
            let relativeHumidity: Int?
            let wind: Double?

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code"
                case isDay = "is_day"
                case relativeHumidity = "relative_humidity_2m"
                case wind = "wind_speed_10m"
            }
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature: [Double?]
            let code: [Int?]
            let precipitation: [Int?]
            let isDay: [Int?]

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case code = "weather_code"
                case precipitation = "precipitation_probability"
                case isDay = "is_day"
            }
        }

        let current: Current
        let hourly: Hourly
        let timezone: String
    }

    static func search(_ name: String) async throws -> [WeatherLocation] {
        let locations: Locations = try await read(host: "geocoding-api.open-meteo.com", path: "/v1/search", query: [
            "name": name, "count": "6", "language": "ru", "format": "json"
        ])
        return locations.results ?? []
    }

    static func forecast(for city: WeatherLocation) async throws -> WeatherReading {
        let forecast: Forecast = try await read(host: "api.open-meteo.com", path: "/v1/forecast", query: [
            "latitude": String(city.latitude), "longitude": String(city.longitude),
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day",
            "hourly": "temperature_2m,weather_code,precipitation_probability,is_day",
            "timezone": "auto", "timeformat": "unixtime", "forecast_hours": "8", "wind_speed_unit": "ms"
        ])
        let now = Date()
        let current = forecast.current
        let hourly = forecast.hourly
        let count = min(hourly.time.count, hourly.temperature.count, hourly.code.count, hourly.precipitation.count, hourly.isDay.count)
        let hours = (0..<count).compactMap { index -> WeatherReading.Hour? in
            let time = Date(timeIntervalSince1970: hourly.time[index])
            guard time > now else { return nil }
            return WeatherReading.Hour(time: time, temperature: hourly.temperature[index],
                                       code: hourly.code[index], precipitation: hourly.precipitation[index],
                                       isDay: hourly.isDay[index].map { $0 == 1 })
        }
        return WeatherReading(city: city.name, temperature: current.temperature2m,
                              feelsLike: current.apparentTemperature, recorded: now, code: current.weatherCode,
                              isDay: current.isDay.map { $0 == 1 }, humidity: current.relativeHumidity,
                              wind: current.wind, timezone: forecast.timezone, hourly: Array(hours.prefix(6)),
                              location: city)
    }

    private static func read<T: Decodable>(host: String, path: String, query: [String: String]) async throws -> T {
        var address = URLComponents()
        address.scheme = "https"
        address.host = host
        address.path = path
        address.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = address.url else { throw URLError(.badURL) }
        let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
}
