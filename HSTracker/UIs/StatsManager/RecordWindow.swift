//
//  RecordWindow.swift
//  HSTracker
//
//  The Win/Loss Record window: the ladder record across every deck and the
//  "No deck" buckets. A trimmed take on HDT's Stats window (Controls/Stats/
//  Constructed: summary, matchups and the games list). Built in code so all of its
//  strings live in Localizable.xcstrings.
//

import AppKit

final class RecordWindow: NSWindowController, NSMenuDelegate, NSWindowDelegate {
    private var filter = RecordFilter.fromSettings()
    private var data: RecordData?
    private var report: RecordReport?
    /// Bumped by every refresh so a slower, older computation is dropped.
    private var refreshToken = 0
    private var needsDataReload = true
    /// A refresh started and not yet applied or dropped.
    private var refreshInFlight = false
    private var observers: [NSObjectProtocol] = []

    private let modePopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let timePopup = NSPopUpButton()
    private let deckPopup = NSPopUpButton()
    private var deckPopupOwners: [RecordOwner?] = []
    private let archivedCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let noDeckCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()

    private let recordLabel = NSTextField(labelWithString: "")
    private let turnOrderLabel = NSTextField(labelWithString: "")
    private let detailsLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let tabView = NSTabView()
    private let decksTab = NSTabViewItem(identifier: "decks")
    private let matchupsTab = NSTabViewItem(identifier: "matchups")
    private let gamesTab = NSTabViewItem(identifier: "games")
    private let rankTab = NSTabViewItem(identifier: "rank")

    private let decksTable = RecordTableController<RecordDeckRow>(columns: RecordColumns.decks(),
                                                                  autosaveName: "RecordDecksTable")
    private let matchupsTable = RecordTableController<RecordMatchupRow>(columns: RecordColumns.matchups(),
                                                                        autosaveName: "RecordMatchupsTable")
    private lazy var gamesTable = RecordTableController<RecordGame>(
        columns: RecordColumns.games(ownerName: { [weak self] owner in
            self?.report?.owners[owner]?.name ?? RecordText.dash
        }),
        autosaveName: "RecordGamesTable")
    private let rankTable = RecordTableController<RecordRankProgression>(columns: RecordColumns.rankProgression(),
                                                                          autosaveName: "RecordRankTable")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = RecordText.localized("Record_WindowTitle")
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        self.init(window: window)

        buildContent(in: window)
        window.center()
        window.setFrameAutosaveName("RecordWindow")
        window.delegate = self

        let center = NotificationCenter.default
        // Games are recorded or deleted, decks renamed, archived or deleted.
        for event in [Events.game_stats_changed, Events.reload_decks] {
            observers.append(center.addObserver(forName: NSNotification.Name(rawValue: event), object: nil,
                                                queue: OperationQueue.main) { [weak self] _ in
                self?.databaseDidChange()
            })
        }
        // Windows of a hidden app are not visible, so changes made meanwhile only
        // marked the data dirty; unhiding does not go through showWindow.
        observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil,
                                            queue: OperationQueue.main) { [weak self] _ in
            self?.refreshIfNeeded()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshIfNeeded()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        refreshIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        if needsDataReload, !refreshInFlight, window?.isVisible == true {
            refresh()
        }
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        for mode in RecordFilter.modes {
            modePopup.addItem(withTitle: RecordText.modeName(mode))
        }
        for format in RecordFilter.formats {
            formatPopup.addItem(withTitle: RecordText.formatName(format))
        }
        for timeFrame in RecordTimeFrame.allCases {
            timePopup.addItem(withTitle: timeFrame.userFacingName)
        }
        deckPopup.addItem(withTitle: RecordText.localized("Record_AllDecks"))
        deckPopupOwners = [nil]
        archivedCheckbox.title = RecordText.localized("Record_IncludeArchived")
        noDeckCheckbox.title = RecordText.localized("Record_IncludeNoDeck")
        for control in [modePopup, formatPopup, timePopup, deckPopup, archivedCheckbox, noDeckCheckbox] {
            control.target = self
            control.action = #selector(filterChanged(_:))
        }
        deckPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncControls()

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let filterRow = NSStackView(views: [
            label("Record_Filter_Mode"), modePopup,
            label("Record_Filter_Format"), formatPopup,
            label("Record_Filter_Time"), timePopup,
            label("Record_Filter_Deck"), deckPopup,
            progressIndicator
        ])
        filterRow.orientation = .horizontal
        filterRow.spacing = 6
        let checkboxRow = NSStackView(views: [archivedCheckbox, noDeckCheckbox])
        checkboxRow.orientation = .horizontal
        checkboxRow.spacing = 16

        recordLabel.font = NSFont.boldSystemFont(ofSize: 15)
        for field in [recordLabel, turnOrderLabel, detailsLabel] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        turnOrderLabel.textColor = .secondaryLabelColor
        detailsLabel.allowsEditingTextAttributes = false
        emptyLabel.stringValue = RecordText.localized("Record_Empty")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        decksTab.label = RecordText.localized("Record_Tab_Decks")
        decksTab.view = decksTable.scrollView
        matchupsTab.label = RecordText.localized("Record_Tab_Matchups")
        matchupsTab.view = matchupsTable.scrollView
        gamesTab.label = RecordText.localized("Record_Tab_Games")
        gamesTab.view = gamesTable.scrollView
        rankTab.label = RecordText.localized("Record_Tab_Rank")
        rankTab.view = rankTable.scrollView
        for item in [decksTab, matchupsTab, gamesTab, rankTab] {
            tabView.addTabViewItem(item)
        }

        decksTable.tableView.target = self
        decksTable.tableView.doubleAction = #selector(deckDoubleClicked(_:))
        let gamesMenu = NSMenu()
        gamesMenu.delegate = self
        gamesMenu.autoenablesItems = false
        gamesMenu.addItem(withTitle: RecordText.localized("Record_DeleteGame"),
                          action: #selector(deleteClickedGame(_:)), keyEquivalent: "").target = self
        gamesTable.tableView.menu = gamesMenu

        let stack = NSStackView(views: [filterRow, checkboxRow, recordLabel, turnOrderLabel, detailsLabel,
                                        emptyLabel, tabView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: checkboxRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            tabView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            recordLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            turnOrderLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detailsLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func label(_ key: String) -> NSTextField {
        return NSTextField(labelWithString: RecordText.localized(key))
    }

    private func syncControls() {
        modePopup.selectItem(at: RecordFilter.modes.firstIndex(of: filter.mode) ?? 0)
        formatPopup.selectItem(at: RecordFilter.formats.firstIndex(of: filter.format) ?? 0)
        timePopup.selectItem(at: RecordTimeFrame.allCases.firstIndex(of: filter.timeFrame) ?? 0)
        archivedCheckbox.state = filter.includeArchived ? .on : .off
        noDeckCheckbox.state = filter.includeNoDeck ? .on : .off
    }

    // MARK: - Loading

    @objc private func filterChanged(_ sender: Any?) {
        var newFilter = filter
        newFilter.mode = RecordFilter.modes[max(modePopup.indexOfSelectedItem, 0)]
        newFilter.format = RecordFilter.formats[max(formatPopup.indexOfSelectedItem, 0)]
        newFilter.timeFrame = RecordTimeFrame.allCases[max(timePopup.indexOfSelectedItem, 0)]
        newFilter.includeArchived = archivedCheckbox.state == .on
        newFilter.includeNoDeck = noDeckCheckbox.state == .on
        let deckIndex = deckPopup.indexOfSelectedItem
        newFilter.owner = deckPopupOwners.indices.contains(deckIndex) ? deckPopupOwners[deckIndex] : nil
        guard newFilter != filter else {
            return
        }
        filter = newFilter
        filter.saveToSettings()
        refresh()
    }

    private func databaseDidChange() {
        needsDataReload = true
        // A miniaturized window is not visible but comes back without showWindow.
        if window?.isVisible == true || window?.isMiniaturized == true {
            refresh()
        } else {
            // Drop a computation still running on the old data.
            refreshToken += 1
            refreshInFlight = false
            progressIndicator.stopAnimation(nil)
        }
    }

    /// Recomputes the report off the main thread, reading Realm again only when the
    /// database changed since the last read.
    private func refresh() {
        assertMainThread()
        refreshToken += 1
        let token = refreshToken
        let filter = self.filter
        let cached = needsDataReload ? nil : data
        refreshInFlight = true
        progressIndicator.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = cached ?? StatsHelper.loadRecordData()
            let report = StatsHelper.buildRecordReport(data: data, filter: filter)
            DispatchQueue.main.async {
                guard let self = self, token == self.refreshToken else {
                    return
                }
                self.data = data
                self.needsDataReload = false
                self.refreshInFlight = false
                self.progressIndicator.stopAnimation(nil)
                self.apply(report)
            }
        }
    }

    private func apply(_ report: RecordReport) {
        assertMainThread()
        // The picked deck was deleted: its games moved to a "No deck" bucket or are
        // gone. Drop the selection instead of showing "All decks" over an empty
        // report that still filters on the deleted deck.
        if let owner = filter.owner, report.filter.owner == owner, report.owners[owner] == nil {
            filter.owner = nil
            refresh()
            return
        }
        self.report = report

        updateDeckPopup(report)
        updateSummary(report.overall)
        emptyLabel.isHidden = report.gameCount > 0

        decksTable.setRows(report.decks)
        matchupsTable.setRows(report.matchups)
        gamesTable.setRows(report.games)
        rankTable.setRows(report.rankProgression)
        gamesTab.label = String(format: RecordText.localized("Record_Tab_GamesCount"), report.gameCount)
        tabView.needsDisplay = true
    }

    private func updateDeckPopup(_ report: RecordReport) {
        var owners: [RecordOwner?] = [nil]
        var titles = [RecordText.localized("Record_AllDecks")]
        for row in report.decks {
            owners.append(row.info.owner)
            titles.append(row.info.name)
        }
        // Keep the selected deck listed even when it has no games under the other filters.
        if let selected = report.filter.owner, !owners.contains(selected), let info = report.owners[selected] {
            owners.append(selected)
            titles.append(info.name)
        }
        deckPopup.removeAllItems()
        for (index, title) in titles.enumerated() {
            // addItem(withTitle:) replaces an item with the same title; decks can share names.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let owner = owners[index], let info = report.owners[owner] {
                // Copy: NSImage(named:) is shared, and resizing it would shrink the icon elsewhere.
                let image = NSImage(named: info.playerClass.rawValue)?.copy() as? NSImage
                image?.size = NSSize(width: 16, height: 16)
                item.image = image
            }
            deckPopup.menu?.addItem(item)
        }
        deckPopupOwners = owners
        deckPopup.selectItem(at: owners.firstIndex(where: { $0 == filter.owner }) ?? 0)
    }

    private func updateSummary(_ summary: RecordSummary) {
        let record = summary.record
        var text = String(format: RecordText.localized("Record_Summary_Record"),
                          record.total, record.wins, record.losses, RecordText.winRate(record))
        if record.draws > 0 {
            text += "  ·  " + String(format: RecordText.localized("Record_Summary_Draws"), record.draws)
        }
        recordLabel.stringValue = text

        var turnOrder = [
            "\(RecordText.localized("Record_GoingFirst")) \(RecordText.winLoss(summary.goingFirst))",
            "\(RecordText.localized("Record_OnCoin")) \(RecordText.winLoss(summary.onCoin))"
        ]
        if summary.unknownTurnOrder > 0 {
            turnOrder.append(String(format: RecordText.localized("Record_Summary_TurnOrderUnknown"),
                                    summary.unknownTurnOrder))
        }
        turnOrderLabel.stringValue = turnOrder.joined(separator: "  ·  ")

        let details = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func append(_ string: String, color: NSColor = .labelColor) {
            details.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        append(RecordText.localized("Record_Summary_Streak") + " ")
        if let streak = summary.streak {
            let key = streak.result == .win ? "Record_Summary_WinStreak" : "Record_Summary_LossStreak"
            append(String(format: RecordText.localized(key), streak.count), color: RecordText.resultColor(streak.result))
        } else {
            append(RecordText.dash)
        }
        append("  ·  " + RecordText.localized("Record_Summary_LastTen") + " ")
        if summary.lastTen.isEmpty {
            append(RecordText.dash)
        }
        // Oldest to newest, reading left to right like a form guide.
        for result in summary.lastTen.reversed() {
            append(RecordText.resultShort(result), color: RecordText.resultColor(result))
        }
        append("  ·  " + RecordText.localized("Record_Summary_AvgTurns") + " "
               + (summary.averageTurns.map { String(format: "%.1f", $0) } ?? RecordText.dash))
        append("  ·  " + RecordText.localized("Record_Summary_AvgDuration") + " "
               + RecordText.duration(summary.averageDuration))
        detailsLabel.attributedStringValue = details
    }

    // MARK: - Actions

    @objc private func deckDoubleClicked(_ sender: Any?) {
        guard let row = decksTable.row(at: decksTable.tableView.clickedRow) else {
            return
        }
        filter.owner = row.info.owner
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = gamesTable.tableView.clickedRow
        for item in menu.items {
            item.isEnabled = gamesTable.row(at: clicked) != nil
        }
    }

    @objc private func deleteClickedGame(_ sender: Any?) {
        guard let game = gamesTable.row(at: gamesTable.tableView.clickedRow), let window = window else {
            return
        }
        let opponent = game.opponentName.isEmpty ? RecordText.className(game.opponentClass) : game.opponentName
        let message = String(format: RecordText.localized("Record_DeleteGame_Confirm"),
                             RecordText.date(game.startTime), opponent, RecordText.result(game.result))
        NSAlert.show(style: .warning, message: message, window: window) {
            if RealmHelper.deleteGameStat(statId: game.statId) {
                NotificationCenter.default.post(name: Notification.Name(rawValue: Events.game_stats_changed),
                                                object: nil)
            } else {
                logger.error("Could not delete game \(game.statId)")
            }
        }
    }
}
