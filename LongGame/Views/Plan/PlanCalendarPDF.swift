import Analysis
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A plan flattened to plain values and drawn as a printable calendar, one month to a
/// page. Holding values rather than models lets it be rendered when a share or save
/// actually asks for the file, which happens off the main actor.
nonisolated struct PlanCalendarDocument: Sendable {
    struct Session: Sendable, Identifiable {
        let id: UUID
        var symbolName: String
        var title: String
        /// Duration, distance and intensity, already formatted.
        var targets: String
        var instructions: String
    }

    struct Phase: Sendable {
        var name: String
        var start: Date
        /// Last day of the phase (inclusive).
        var end: Date
    }

    var name: String
    var start: Date
    var end: Date
    var goalTitle: String?
    var goalDate: Date?
    var phases: [Phase] = []
    /// Sessions keyed by the start of their day.
    var sessions: [Date: [Session]] = [:]

    var fileName: String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return "\(safe.isEmpty ? "Training Plan" : safe).pdf"
    }

    var subtitle: String {
        var parts = [(start..<end).formatted(.interval.day().month(.abbreviated).year())]
        if let goalTitle, !goalTitle.isEmpty { parts.append("Goal: \(goalTitle)") }
        return parts.joined(separator: " · ")
    }

    func phase(on day: Date) -> Phase? {
        phases.first { $0.start <= day && day <= $0.end }
    }

    /// The calendar as PDF data. Empty if the PDF context cannot be created.
    @MainActor func pdfData(calendar: Calendar = .current) -> Data {
        let months = PlanCalendar.months(from: start, through: end, calendar: calendar)
        let size = PlanCalendarPage.paperSize()
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
            let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        for (index, month) in months.enumerated() {
            let page = PlanCalendarPage(
                document: self, month: month, pageNumber: index + 1, pageCount: months.count, calendar: calendar
            )
            .frame(width: size.width, height: size.height)
            ImageRenderer(content: page).render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return data as Data
    }
}

nonisolated extension PlanCalendarDocument: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { document in
            await document.pdfData()
        }
        .suggestedFileName { $0.fileName }
    }
}

/// One month of the plan on a landscape page. Sizes are in points and colors are fixed:
/// this is drawn for paper, not for the screen.
private struct PlanCalendarPage: View {
    let document: PlanCalendarDocument
    let month: Date
    let pageNumber: Int
    let pageCount: Int
    let calendar: Calendar

    private static let ink = Color.black
    private static let faded = Color(white: 0.4)
    private static let rule = Color(white: 0.7)

    /// US Letter where it is the everyday paper size, A4 everywhere else.
    static func paperSize(locale: Locale = .current) -> CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO"]
        let usesLetter = locale.region.map { letterRegions.contains($0.identifier) } ?? false
        return usesLetter ? CGSize(width: 792, height: 612) : CGSize(width: 842, height: 595)
    }

    private var weeks: [[Date?]] {
        let cells = PlanCalendar.monthGrid(containing: month, calendar: calendar)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(document.name).font(.system(size: 11, weight: .semibold))
                    Text(document.subtitle).font(.system(size: 8)).foregroundStyle(Self.faded)
                }
            }

            VStack(spacing: 3) {
                HStack(spacing: 0) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol.uppercased())
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Self.faded)
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                cell(for: day)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .clipped()
                                    .overlay { Rectangle().stroke(Self.rule, lineWidth: 0.5) }
                            }
                        }
                    }
                }
            }

            HStack {
                Text("Long Game")
                Spacer()
                Text("Page \(pageNumber) of \(pageCount)")
            }
            .font(.system(size: 7))
            .foregroundStyle(Self.faded)
        }
        .foregroundStyle(Self.ink)
        .padding(36)
        .background(.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func cell(for day: Date?) -> some View {
        if let day {
            let sessions = document.sessions[day] ?? []
            let inPlan = calendar.startOfDay(for: document.start) <= day && day <= document.end
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(inPlan ? Self.ink : Self.rule)
                    Spacer(minLength: 2)
                    if let label = phaseLabel(on: day) {
                        Text(label.uppercased())
                            .font(.system(size: 5.5, weight: .semibold))
                            .foregroundStyle(Self.faded)
                            .lineLimit(1)
                    }
                }
                if let goalTitle = document.goalTitle, let goalDate = document.goalDate,
                    calendar.isDate(goalDate, inSameDayAs: day)
                {
                    Label(goalTitle, systemImage: "flag.checkered")
                        .labelStyle(SessionLabelStyle())
                        .font(.system(size: 7, weight: .bold))
                        .lineLimit(2)
                }
                // The fullest version that fits the cell: a busy day drops the
                // instructions first, then goes down to one line a session.
                ViewThatFits(in: .vertical) {
                    sessionList(sessions, detail: .full)
                    sessionList(sessions, detail: .targets)
                    sessionList(sessions, detail: .oneLine)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(4)
        } else {
            Color(white: 0.96)
        }
    }

    /// Named where a phase begins and again at the top of each page.
    private func phaseLabel(on day: Date) -> String? {
        guard let phase = document.phase(on: day) else { return nil }
        let opensPage = calendar.component(.day, from: day) == 1
        return calendar.isDate(phase.start, inSameDayAs: day) || opensPage ? phase.name : nil
    }

    private enum Detail { case full, targets, oneLine }

    private func sessionList(_ sessions: [PlanCalendarDocument.Session], detail: Detail) -> some View {
        VStack(alignment: .leading, spacing: detail == .oneLine ? 2 : 4) {
            ForEach(sessions) { session in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 7, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if detail != .oneLine, !session.targets.isEmpty {
                            Text(session.targets).lineLimit(2)
                        }
                        if detail == .full, !session.instructions.isEmpty, session.instructions != session.targets {
                            Text(session.instructions).foregroundStyle(Self.faded).lineLimit(3)
                        }
                    }
                } icon: {
                    Image(systemName: session.symbolName)
                }
                .labelStyle(SessionLabelStyle())
            }
        }
        .font(.system(size: 6.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small icon in a fixed column, so session text lines up down the cell.
private struct SessionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon.font(.system(size: 6.5)).frame(width: 9)
            configuration.title
        }
    }
}
