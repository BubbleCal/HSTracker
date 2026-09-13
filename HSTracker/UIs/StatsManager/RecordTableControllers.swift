//
//  RecordTableControllers.swift
//  HSTracker
//
//  Tables and display strings of the Win/Loss Record window.
//

import AppKit

/// Display strings of the record. Main thread only (shared formatters).
enum RecordText {
    static let dash = "–"

    private static var appLocale: Locale {
        return Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()

    static func localized(_ key: String) -> String {
        return String.localizedString(key, comment: "")
    }

    static func winRate(_ record: StatsDeckRecord) -> String {
        let rate = StatsHelper.getDeckWinRate(record: record)
        return rate < 0 ? dash : "\(Int((rate * 100).rounded()))%"
    }

    /// "W-L (x%)", or a dash without games.
    static func winLoss(_ record: StatsDeckRecord) -> String {
        guard record.total > 0 else {
            return dash
        }
        return "\(record.wins)-\(record.losses) (\(winRate(record)))"
    }

    static func className(_ playerClass: CardClass) -> String {
        return String.localizedString(playerClass.rawValue, comment: "")
    }

    static func modeName(_ mode: GameMode) -> String {
        return mode == .all ? localized("Record_Mode_Ladder") : mode.userFacingName
    }

    static func formatName(_ format: Format?) -> String {
        switch format {
        case .all: return localized("Record_Format_All")
        case .standard: return localized("Record_Format_Standard")
        case .wild: return localized("Record_Format_Wild")
        case .classic: return localized("Record_Format_Classic")
        case .twist: return localized("Record_Format_Twist")
        case .unknown, .none: return dash
        }
    }

    static func turnOrder(_ coin: Bool?) -> String {
        switch coin {
        case .some(false): return localized("Record_GoingFirst")
        case .some(true): return localized("Record_OnCoin")
        case .none: return dash
        }
    }

    static func result(_ result: GameResult) -> String {
        switch result {
        case .win: return localized("Record_Result_Win")
        case .loss: return localized("Record_Result_Loss")
        case .draw: return localized("Record_Result_Draw")
        case .unknown: return localized("Record_Result_Unknown")
        }
    }

    static func resultShort(_ result: GameResult) -> String {
        switch result {
        case .win: return localized("Record_Result_WinShort")
        case .loss: return localized("Record_Result_LossShort")
        case .draw: return localized("Record_Result_DrawShort")
        case .unknown: return dash
        }
    }

    static func resultColor(_ result: GameResult) -> NSColor {
        switch result {
        case .win: return .systemGreen
        case .loss: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    static func gameResult(_ game: RecordGame) -> String {
        let text = result(game.result)
        return game.wasConceded ? "\(text) \(localized("Record_Result_Conceded"))" : text
    }

    static func duration(_ duration: TimeInterval?) -> String {
        guard let duration = duration else {
            return dash
        }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func date(_ date: Date?) -> String {
        guard let date = date else {
            return dash
        }
        return dateFormatter.string(from: date)
    }

    /// Seasons are calendar months (Database.season), so name them by month.
    static func season(_ season: Int) -> String {
        let months = season + 2 // season 1 is April 2014
        var components = DateComponents()
        components.year = 2014 + months / 12
        components.month = months % 12 + 1
        components.day = 15
        guard season > 0, let date = Calendar(identifier: .gregorian).date(from: components) else {
            return dash
        }
        return monthFormatter.string(from: date)
    }

    static func rank(_ rank: RankSnapshot?) -> String {
        guard let rank = rank else {
            return dash
        }
        if rank.isLegendLevel {
            if rank.legendRank > 0 {
                return String(format: localized("Record_Rank_Legend"), rank.legendRank)
            }
            return localized("Record_League_Legend")
        }
        let leagues = ["Record_League_Bronze", "Record_League_Silver", "Record_League_Gold",
                       "Record_League_Platinum", "Record_League_Diamond"]
        let level = max(rank.starLevel - 1, 0)
        let league = localized(leagues[min(level / 10, leagues.count - 1)])
        return String(format: localized("Record_Rank_Stars"), league, 10 - level % 10, rank.stars)
    }

    static func signed(_ value: Int) -> String {
        return value > 0 ? "+\(value)" : "\(value)"
    }

    /// "before → after (+stars)".
    static func rankChange(before: RankSnapshot?, after: RankSnapshot?) -> String {
        guard before != nil || after != nil else {
            return dash
        }
        var text = "\(rank(before)) → \(rank(after))"
        if let before = before, let after = after, !(before.isLegendLevel && after.isLegendLevel) {
            text += " (\(signed(after.ladderStars - before.ladderStars)))"
        }
        return text
    }
}

/// One column of a record table.
struct RecordColumn<Row> {
    let id: String
    let title: String
    let width: CGFloat
    var alignment: NSTextAlignment = .left
    /// Whether the first click on the header sorts ascending.
    var ascendingFirst = false
    let text: (Row) -> String
    var image: ((Row) -> NSImage?)?
    var color: ((Row) -> NSColor?)?
    var toolTip: ((Row) -> String?)?
    let less: (Row, Row) -> Bool
}

/// Data source and delegate of a code-built, sortable NSTableView.
final class RecordTableController<Row>: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    private let columns: [RecordColumn<Row>]
    private var unsortedRows: [Row] = []
    private(set) var rows: [Row] = []

    init(columns: [RecordColumn<Row>], autosaveName: String) {
        self.columns = columns
        super.init()

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.headerCell.alignment = column.alignment
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: column.ascendingFirst)
            tableView.addTableColumn(tableColumn)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 22
        tableView.autosaveName = autosaveName
        tableView.autosaveTableColumns = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    func setRows(_ rows: [Row]) {
        assertMainThread()
        unsortedRows = rows
        applySort()
        tableView.reloadData()
    }

    func row(at index: Int) -> Row? {
        return rows.indices.contains(index) ? rows[index] : nil
    }

    private func applySort() {
        guard let descriptor = tableView.sortDescriptors.first,
              let column = columns.first(where: { $0.id == descriptor.key }) else {
            rows = unsortedRows
            return
        }
        // Sort indices so equal rows keep the report's order.
        let indexed = unsortedRows.enumerated().sorted { lhs, rhs in
            if column.less(lhs.element, rhs.element) {
                return descriptor.ascending
            }
            if column.less(rhs.element, lhs.element) {
                return !descriptor.ascending
            }
            return lhs.offset < rhs.offset
        }
        rows = indexed.map { $0.element }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn,
              let column = columns.first(where: { $0.id == tableColumn.identifier.rawValue }),
              let item = self.row(at: row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("RecordCell.\(column.id)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier, withImage: column.image != nil)
        cell.textField?.stringValue = column.text(item)
        cell.textField?.alignment = column.alignment
        cell.textField?.textColor = column.color?(item) ?? .labelColor
        cell.imageView?.image = column.image?(item)
        cell.toolTip = column.toolTip?(item)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort()
        tableView.reloadData()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(textField)
        cell.textField = textField

        var constraints = [
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ]
        if withImage {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView
            constraints += [
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4)
            ]
        } else {
            constraints.append(textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

// MARK: - Column sets

enum RecordColumns {
    private static func classImage(_ playerClass: CardClass) -> NSImage? {
        return NSImage(named: playerClass.rawValue)
    }

    /// Win rate first, then games, so rows without a win rate sort last.
    private static func lessWinRate(_ lhs: StatsDeckRecord, _ rhs: StatsDeckRecord) -> Bool {
        let left = StatsHelper.getDeckWinRate(record: lhs)
        let right = StatsHelper.getDeckWinRate(record: rhs)
        return left != right ? left < right : lhs.total < rhs.total
    }

    private static func summaryColumns<Row>(_ summary: @escaping (Row) -> RecordSummary) -> [RecordColumn<Row>] {
        return [
            RecordColumn(id: "games", title: RecordText.localized("Record_Column_Games"), width: 60,
                         alignment: .right, text: { "\(summary($0).record.total)" },
                         less: { summary($0).record.total < summary($1).record.total }),
            RecordColumn(id: "wins", title: RecordText.localized("Record_Column_Wins"), width: 50,
                         alignment: .right, text: { "\(summary($0).record.wins)" },
                         less: { summary($0).record.wins < summary($1).record.wins }),
            RecordColumn(id: "losses", title: RecordText.localized("Record_Column_Losses"), width: 50,
                         alignment: .right, text: { "\(summary($0).record.losses)" },
                         less: { summary($0).record.losses < summary($1).record.losses }),
            RecordColumn(id: "winrate", title: RecordText.localized("Record_Column_WinRate"), width: 60,
                         alignment: .right, text: { RecordText.winRate(summary($0).record) },
                         less: { lessWinRate(summary($0).record, summary($1).record) }),
            RecordColumn(id: "first", title: RecordText.localized("Record_GoingFirst"), width: 100,
                         alignment: .right, text: { RecordText.winLoss(summary($0).goingFirst) },
                         less: { lessWinRate(summary($0).goingFirst, summary($1).goingFirst) }),
            RecordColumn(id: "coin", title: RecordText.localized("Record_OnCoin"), width: 100,
                         alignment: .right, text: { RecordText.winLoss(summary($0).onCoin) },
                         less: { lessWinRate(summary($0).onCoin, summary($1).onCoin) })
        ]
    }

    static func decks() -> [RecordColumn<RecordDeckRow>] {
        var columns: [RecordColumn<RecordDeckRow>] = [
            RecordColumn(id: "deck", title: RecordText.localized("Record_Column_Deck"), width: 220,
                         ascendingFirst: true,
                         text: { row in
                            row.info.isArchived
                                ? "\(row.info.name) \(RecordText.localized("Record_Archived"))" : row.info.name
                         },
                         image: { classImage($0.info.playerClass) },
                         color: { $0.info.isArchived ? .secondaryLabelColor : nil },
                         toolTip: { $0.info.name },
                         less: { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending })
        ]
        columns += summaryColumns { $0.summary }
        columns.append(RecordColumn(id: "last", title: RecordText.localized("Record_Column_LastPlayed"),
                                    width: 130, text: { RecordText.date($0.summary.lastPlayed) },
                                    less: { ($0.summary.lastPlayed ?? .distantPast)
                                        < ($1.summary.lastPlayed ?? .distantPast) }))
        return columns
    }

    static func matchups() -> [RecordColumn<RecordMatchupRow>] {
        var columns: [RecordColumn<RecordMatchupRow>] = [
            RecordColumn(id: "class", title: RecordText.localized("Record_Column_OpponentClass"), width: 140,
                         ascendingFirst: true,
                         text: { RecordText.className($0.opponentClass) },
                         image: { classImage($0.opponentClass) },
                         less: { RecordText.className($0.opponentClass)
                            .localizedStandardCompare(RecordText.className($1.opponentClass)) == .orderedAscending })
        ]
        columns += summaryColumns { $0.summary }
        columns.append(RecordColumn(
            id: "ci", title: RecordText.localized("Record_Column_CI"), width: 100, alignment: .right,
            ascendingFirst: true,
            text: { StatsHelper.getDeckConfidenceString(record: $0.summary.record,
                                                        confidence: StatsHelper.statsUIConfidence) },
            toolTip: { _ in
                String.localizedString("It is 90% certain that the true winrate falls between these values.",
                                       comment: "")
            },
            less: { confidenceWidth($0.summary.record) < confidenceWidth($1.summary.record) }))
        return columns
    }

    private static func confidenceWidth(_ record: StatsDeckRecord) -> Double {
        let interval = StatsHelper.binomialProportionCondifenceInterval(wins: record.wins, losses: record.losses,
                                                                        confidence: StatsHelper.statsUIConfidence)
        return interval.upper - interval.lower
    }

    static func games(ownerName: @escaping (RecordOwner) -> String) -> [RecordColumn<RecordGame>] {
        return [
            RecordColumn(id: "date", title: RecordText.localized("Record_Column_Date"), width: 140,
                         text: { RecordText.date($0.startTime) },
                         less: { $0.startTime < $1.startTime }),
            RecordColumn(id: "deck", title: RecordText.localized("Record_Column_Deck"), width: 160,
                         ascendingFirst: true,
                         text: { ownerName($0.owner) },
                         image: { classImage($0.playerClass) },
                         less: { ownerName($0.owner).localizedStandardCompare(ownerName($1.owner)) == .orderedAscending }),
            RecordColumn(id: "opponent", title: RecordText.localized("Record_Column_Opponent"), width: 150,
                         ascendingFirst: true,
                         text: { $0.opponentName.isEmpty ? RecordText.className($0.opponentClass) : $0.opponentName },
                         image: { classImage($0.opponentClass) },
                         toolTip: { RecordText.className($0.opponentClass) },
                         less: { RecordText.className($0.opponentClass)
                            .localizedStandardCompare(RecordText.className($1.opponentClass)) == .orderedAscending }),
            RecordColumn(id: "result", title: RecordText.localized("Record_Column_Result"), width: 110,
                         text: { RecordText.gameResult($0) },
                         color: { RecordText.resultColor($0.result) },
                         less: { $0.result.rawValue < $1.result.rawValue }),
            RecordColumn(id: "coin", title: RecordText.localized("Record_Column_TurnOrder"), width: 60,
                         text: { RecordText.turnOrder($0.coin) },
                         less: { ($0.coin.map { $0 ? 2 : 1 } ?? 0) < ($1.coin.map { $0 ? 2 : 1 } ?? 0) }),
            RecordColumn(id: "rank", title: RecordText.localized("Record_Column_Rank"), width: 220,
                         text: { RecordText.rankChange(before: $0.rankBefore, after: $0.rankAfter) },
                         less: { lessRank($0.rankBefore, $1.rankBefore) }),
            RecordColumn(id: "mode", title: RecordText.localized("Record_Column_Mode"), width: 90,
                         ascendingFirst: true,
                         text: { RecordText.modeName($0.mode) },
                         less: { $0.mode.rawValue < $1.mode.rawValue }),
            RecordColumn(id: "format", title: RecordText.localized("Record_Column_Format"), width: 60,
                         ascendingFirst: true,
                         text: { RecordText.formatName($0.format) },
                         less: { RecordText.formatName($0.format) < RecordText.formatName($1.format) }),
            RecordColumn(id: "turns", title: RecordText.localized("Record_Column_Turns"), width: 50,
                         alignment: .right,
                         text: { $0.turns > 0 ? "\($0.turns)" : RecordText.dash },
                         less: { $0.turns < $1.turns }),
            RecordColumn(id: "duration", title: RecordText.localized("Record_Column_Duration"), width: 60,
                         alignment: .right,
                         text: { RecordText.duration($0.duration) },
                         less: { ($0.duration ?? -1) < ($1.duration ?? -1) })
        ]
    }

    private static func lessRank(_ lhs: RankSnapshot?, _ rhs: RankSnapshot?) -> Bool {
        guard let rhs = rhs else {
            return false
        }
        guard let lhs = lhs else {
            return true
        }
        return rhs.isHigher(than: lhs)
    }

    static func rankProgression() -> [RecordColumn<RecordRankProgression>] {
        return [
            RecordColumn(id: "season", title: RecordText.localized("Record_Column_Season"), width: 120,
                         text: { RecordText.season($0.season) },
                         less: { $0.season < $1.season }),
            RecordColumn(id: "format", title: RecordText.localized("Record_Column_Format"), width: 70,
                         ascendingFirst: true,
                         text: { RecordText.formatName($0.format) },
                         less: { RecordText.formatName($0.format) < RecordText.formatName($1.format) }),
            RecordColumn(id: "games", title: RecordText.localized("Record_Column_Games"), width: 60,
                         alignment: .right, text: { "\($0.games)" },
                         less: { $0.games < $1.games }),
            RecordColumn(id: "start", title: RecordText.localized("Record_Column_StartRank"), width: 130,
                         text: { RecordText.rank($0.start) },
                         less: { lessRank($0.start, $1.start) }),
            RecordColumn(id: "current", title: RecordText.localized("Record_Column_CurrentRank"), width: 130,
                         text: { RecordText.rank($0.current) },
                         less: { lessRank($0.current, $1.current) }),
            RecordColumn(id: "peak", title: RecordText.localized("Record_Column_PeakRank"), width: 130,
                         text: { RecordText.rank($0.peak) },
                         less: { lessRank($0.peak, $1.peak) }),
            RecordColumn(id: "net", title: RecordText.localized("Record_Column_NetStars"), width: 80,
                         alignment: .right,
                         text: { $0.netStars.map { RecordText.signed($0) } ?? RecordText.dash },
                         color: { row in
                            guard let net = row.netStars, net != 0 else { return nil }
                            return net > 0 ? .systemGreen : .systemRed
                         },
                         less: { ($0.netStars ?? Int.min) < ($1.netStars ?? Int.min) })
        ]
    }
}
