import SwiftUI

/// Weeks or months side by side, so a swipe moves to the next one. `anchor` stays the
/// selected day: paging carries it along by whole periods, and changing it from outside
/// (the arrows, Today, a tapped day) scrolls to its page.
struct PeriodPager<Page: View>: View {
    private let unit: Calendar.Component
    @Binding private var anchor: Date
    private let page: (Date) -> Page

    /// The first day of every period that can be reached.
    @State private var starts: [Date]
    @State private var position: Date?

    /// Periods either side of the starting one: far enough that the ends are never met.
    private static var reach: Int { 520 }

    init(unit: Calendar.Component, anchor: Binding<Date>, @ViewBuilder page: @escaping (Date) -> Page) {
        self.unit = unit
        _anchor = anchor
        self.page = page
        let calendar = Calendar.current
        let day = anchor.wrappedValue
        let origin = calendar.dateInterval(of: unit, for: day)?.start ?? calendar.startOfDay(for: day)
        _starts = State(
            initialValue: (-Self.reach...Self.reach).compactMap { calendar.date(byAdding: unit, value: $0, to: origin) }
        )
        _position = State(initialValue: origin)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(starts, id: \.self) { start in
                    page(start).containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $position)
        .onChange(of: position) { _, position in
            guard let from = index(of: anchor), let to = position.flatMap(starts.firstIndex(of:)), from != to,
                let moved = Calendar.current.date(byAdding: unit, value: to - from, to: anchor)
            else { return }
            anchor = moved
        }
        .onChange(of: anchor) { _, anchor in
            guard let index = index(of: anchor), starts[index] != position else { return }
            withAnimation { position = starts[index] }
        }
    }

    /// The page holding `date`.
    private func index(of date: Date) -> Int? {
        starts.lastIndex { $0 <= date }
    }
}
