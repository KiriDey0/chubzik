import EventKit
import SwiftUI

struct CalendarPanel: View {
    let scale: CGFloat
    let accent: Color
    let tile: Color
    let muted: Color
    let sample: [CalendarEntry]?

    @ObservedObject var feed: CalendarFeed
    @Binding var month: Date
    @Binding var selection: Date

    private let calendar = CalendarMonth.calendar
    private let locale = Locale(identifier: "ru_RU")
    private let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    var body: some View {
        let grid = CalendarMonth(containing: month)
        HStack(alignment: .top, spacing: 14 * scale) {
            monthGrid(grid)
                .frame(maxWidth: .infinity, alignment: .top)
            eventList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(9 * scale)
                .background(tile, in: RoundedRectangle(cornerRadius: 9 * scale))
        }
        .environment(\.locale, locale)
        .environment(\.calendar, calendar)
        .task(id: month) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in load() }
    }

    private func monthGrid(_ grid: CalendarMonth) -> some View {
        VStack(spacing: 2 * scale) {
            HStack(spacing: 5 * scale) {
                monthButton(-1, icon: "chevron.left", label: "Предыдущий месяц")
                Spacer(minLength: 2)
                Text(month, format: .dateTime.month(.wide).year())
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                monthButton(1, icon: "chevron.right", label: "Следующий месяц")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: 7), spacing: 0) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day).font(.system(size: 8 * scale)).foregroundStyle(muted)
                        .frame(height: 13 * scale)
                }
                ForEach(grid.days.indices, id: \.self) { index in
                    if let date = grid.days[index] {
                        dayButton(date)
                    } else {
                        Color.clear.frame(height: 15 * scale).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = date == selection
        let hasEvents = !events(on: date).isEmpty
        let today = calendar.isDateInToday(date)
        return Button {
            selection = date
        } label: {
            Text(calendar.component(.day, from: date).formatted())
                .font(.system(size: 9 * scale, weight: today || selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? accent : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 15 * scale)
                .background(selected ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) {
                    if hasEvents {
                        Circle().fill(accent).frame(width: 2.5, height: 2.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.day().month(.wide).year().locale(locale)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(spacing: 3) {
                Text(selection, format: .dateTime.day().month(.wide))
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Button("Сегодня") {
                    selection = calendar.startOfDay(for: .now)
                    month = CalendarMonth(containing: selection).interval.start
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .font(.system(size: 9 * scale))
            }
            Divider()
            if sample != nil || feed.access == .available {
                let entries = events(on: selection)
                if entries.isEmpty {
                    Text("Событий нет").foregroundStyle(muted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7 * scale) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).fontWeight(.medium).lineLimit(2)
                                    if entry.allDay {
                                        Text("Весь день").foregroundStyle(muted)
                                    } else {
                                        let format = Date.FormatStyle.dateTime.hour().minute()
                                        let end = calendar.isDate(entry.start, inSameDayAs: entry.end)
                                            ? entry.end.formatted(format)
                                            : entry.end.formatted(format.day().month())
                                        Text(entry.start.formatted(format) + "–" + end)
                                            .foregroundStyle(muted)
                                    }
                                    if let link = entry.link {
                                        Link(destination: link) {
                                            Label("Открыть ссылку", systemImage: "arrow.up.right")
                                        }
                                        .foregroundStyle(accent)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else if feed.access == .undecided {
                Button("Подключить календарь") {
                    Task { @MainActor in
                        await feed.request()
                        load()
                    }
                }
                .controlSize(.small)
            } else {
                Text("Доступ к событиям можно включить в настройках macOS.").foregroundStyle(muted)
            }
        }
        .font(.system(size: 10 * scale))
    }

    private func events(on day: Date) -> [CalendarEntry] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return (sample ?? feed.entries).filter { $0.overlaps(interval) }
    }

    private func load() {
        if sample == nil { feed.load(CalendarMonth(containing: month).interval) }
    }

    private func monthButton(_ offset: Int, icon: String, label: String) -> some View {
        Button {
            guard let date = calendar.date(byAdding: .month, value: offset, to: month) else { return }
            month = date
            selection = calendar.isDate(date, equalTo: .now, toGranularity: .month)
                ? calendar.startOfDay(for: .now) : date
        } label: {
            Image(systemName: icon).font(.system(size: 9 * scale, weight: .semibold))
                .foregroundStyle(accent).frame(width: 18 * scale, height: 18 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
