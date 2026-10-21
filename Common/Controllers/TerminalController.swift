//
//  TerminalController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import SwiftTerm
import os.log

public protocol TerminalControllerDelegate: AnyObject {
	/// `droppedRows` rows went off the top since the last refresh, as a full scrollback drops its
	/// oldest lines, so every row still there moved up by that many.
	func refresh(lines: [AnyView], droppedRows: Int)
	func activateBell()
	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool)
	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?)
	func didReceiveKeyboardInput()

	func saveFile(url: URL)
	func fileUploadRequested()

	func close()
	func didReceiveError(error: Error)
}

public class TerminalController {

	public weak var delegate: TerminalControllerDelegate?

	/// The style the terminal is drawn with. The string supplier, which belongs to the terminal
	/// queue, gets its own copy there.
	public private(set) var colorMap = Preferences.shared.colorMap
	public private(set) var fontMetrics = Preferences.shared.fontMetrics

	internal var terminal: Terminal?
	private var subProcess: SubProcess?
	private var subProcessFailureError: Error?
	private let stringSupplier = StringSupplier()

	// Rows here count from the oldest line the terminal still holds, as getTopVisibleRow() and
	// getScrollInvariantUpdateRange() do. getScrollInvariantLine(row:) counts from the first line it
	// ever held instead. Once the scrollback is full, each new line drops the oldest one and adds
	// one to SwiftTerm's linesTop (not public) rather than moving the screen down, so the two part.
	// These belong to the terminal queue.

	/// SwiftTerm's linesTop: how many lines the full scrollback has dropped, found each update.
	internal private(set) var linesTop = 0
	/// linesTop as of the rows the view last showed, kept on main, as text selection counts rows the
	/// way the view does. It changes along with them, after the terminal queue's has.
	internal private(set) var shownLinesTop = 0
	private var lines = [AnyView]()
	/// The terminal as `lines` last showed it, to tell how its lines have moved since.
	private var linesState = LinesState()
	/// The rows of the screen that isn't showing (normal or alternate), to show again when it's back.
	private var otherScreenLines: (lines: [AnyView], state: LinesState)?
	private var screenDidChange = false
	private var needsFullRedraw = false

	private var processLaunchDate: Date?
	private var updateTimer: CADisplayLink?
	private var refreshRate: TimeInterval = 60
	private var isTabVisible = true
	private var isWindowVisible = true
	private var isVisible: Bool { isTabVisible && isWindowVisible }
	private var isDirty = false {
		didSet { updateTitle() }
	}
	private var hasBell = false {
		didSet { updateTitle() }
	}
	private var readBuffer = [UTF8Char]()

	/// The size the terminal was last asked to be, as its own size belongs to the terminal queue.
	private var terminalSize = (cols: 0, rows: 0)

	internal var terminalQueue = DispatchQueue(label: "ws.hbang.Terminal.terminal-queue")

	public var screenSize: ScreenSize? {
		didSet { updateScreenSize() }
	}
	public var scrollbackLines: Int { terminal?.getTopVisibleRow() ?? 0 }

	private var lastBellDate: Date?

	internal var title: String?
	internal var userAndHostname: String?
	internal var user: String?
	internal var hostname: String?
	internal var isLocalhost: Bool { hostname == nil || hostname == ProcessInfo.processInfo.hostName }
	internal var currentWorkingDirectory: URL?
	internal var currentFile: URL?

	internal var iTermIntegrationVersion: String?
	internal var shell: String?

	internal var logger = Logger(subsystem: "ws.hbang.Terminal", category: "TerminalController")

	public init() {
		let options = TerminalOptions(termName: "xterm-256color",
																	scrollback: 10_000)
		let terminal = Terminal(delegate: self, options: options)
		self.terminal = terminal
		terminalSize = (terminal.cols, terminal.rows)

		stringSupplier.terminal = terminal

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		preferencesUpdated()

		startUpdateTimer(fps: refreshRate)

		NotificationCenter.default.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

		UIDevice.current.isBatteryMonitoringEnabled = true
		NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)

		if #available(macOS 12, *) {
			NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
		}
	}

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		let colorMap = preferences.colorMap
		let fontMetrics = preferences.fontMetrics
		self.colorMap = colorMap
		self.fontMetrics = fontMetrics

		powerStateChanged()

		// Redraw every row, not just the screen, or the scrollback keeps the old colours and font.
		terminalQueue.async {
			self.stringSupplier.colorMap = colorMap
			self.stringSupplier.fontMetrics = fontMetrics
			self.otherScreenLines = nil
			self.needsFullRedraw = true
		}
	}

	@objc private func powerStateChanged() {
		let preferences = Preferences.shared
		if #available(macOS 12, *),
			 ProcessInfo.processInfo.isLowPowerModeEnabled && preferences.reduceRefreshRateInLPM {
			refreshRate = 15
		} else {
			let currentRate = UIDevice.current.batteryState == .unplugged ? preferences.refreshRateOnBattery : preferences.refreshRateOnAC
			refreshRate = TimeInterval(min(currentRate, UIScreen.main.maximumFramesPerSecond))
		}
		if isVisible {
			startUpdateTimer(fps: refreshRate)
		}
	}

	public func windowDidEnterBackground() {
		// Throttle the update timer to save battery. On iPhone, we shouldn’t be visible at all in this
		// case, so throttle right down to once per second so we can maintain the dirty bit.
		startUpdateTimer(fps: UIApplication.shared.supportsMultipleScenes ? 10 : 1)
		isWindowVisible = false
	}

	public func windowWillEnterForeground() {
		// Go back to full speed.
		isWindowVisible = true
		if isVisible {
			startUpdateTimer(fps: refreshRate)
		}
	}

	@objc private func appWillResignActive() {
		stopUpdatingTimer()
		isWindowVisible = false
	}

	@objc private func appDidBecomeActive() {
		startUpdateTimer(fps: refreshRate)
		isWindowVisible = true
	}

	public func terminalWillAppear() {
		// Start updating again.
		startUpdateTimer(fps: refreshRate)
		isTabVisible = true
	}

	public func terminalWillDisappear() {
		// Not visible, so throttle right down to once per second so we can maintain the dirty bit.
		startUpdateTimer(fps: 1)
		isTabVisible = false
	}

	private func startUpdateTimer(fps: TimeInterval) {
		updateTimer?.invalidate()
		updateTimer = CADisplayLink(target: self, selector: #selector(self.updateTimerFired))
		updateTimer?.preferredFramesPerSecond = Int(fps)
		updateTimer?.add(to: .main, forMode: .default)
	}

	private func stopUpdatingTimer() {
		updateTimer?.invalidate()
		updateTimer = nil
	}

	// MARK: - Sub Process

	public func startSubProcess() throws {
		subProcess = SubProcess()
		subProcess!.delegate = self
		processLaunchDate = Date()
		do {
			try subProcess!.start()
		} catch {
			subProcessFailureError = error
			throw error
		}
	}

	public func stopSubProcess() throws {
		defer { stopUpdatingTimer() }
		do {
			try subProcess!.stop()
		} catch SubProcessIllegalStateError.notStarted {
			// It already ended, as when the shell exits and its pane closes.
		}
	}

	// MARK: - Terminal

	public func readInputStream(_ data: [UTF8Char]) {
		terminalQueue.async {
			self.readBuffer += data
		}
	}

	private func readInputStream(_ data: Data) {
		readInputStream([UTF8Char](data))
	}

	public func write(_ data: [UTF8Char]) {
		subProcess?.write(data: data)
	}

	public func write(_ data: Data) {
		write([UTF8Char](data))
	}

	@objc private func updateTimerFired() {
		terminalQueue.async {
			if !self.readBuffer.isEmpty {
				self.terminal?.feed(byteArray: self.readBuffer)
				self.readBuffer.removeAll()
			}

			guard let terminal = self.terminal else {
				return
			}
			self.updateLines(terminal: terminal)
		}
	}

	/// Where the rows in `lines` were in the terminal when they were last brought up to date.
	private struct LinesState {
		var topVisibleRow = 0
		var cols = 0
		var linesTop = 0
		var cursorLocation: (x: Int, y: Int) = (-1, -1)
		/// The last line of scrollback, above the screen, and its row. Lines in the scrollback only
		/// ever move up, when lines are dropped from the top, so finding it again tells how far.
		var anchor: (row: Int, line: BufferLine)?
	}

	/// The line in `row`, counting rows as the terminal view does. Terminal queue only.
	internal func line(atRow row: Int) -> BufferLine? {
		terminal?.getScrollInvariantLine(row: row + linesTop)
	}

	/// Finds SwiftTerm's linesTop. getScrollInvariantLine(row:) returns nil for the rows it dropped,
	/// then lines, so it's the first row that has one.
	private func findLinesTop(near guess: Int, in terminal: Terminal) -> Int {
		func holds(_ row: Int) -> Bool { terminal.getScrollInvariantLine(row: row) != nil }
		func isFirst(_ row: Int) -> Bool { holds(row) && (row == 0 || !holds(row - 1)) }
		if isFirst(guess) {
			return guess
		}
		if isFirst(0) {
			return 0
		}
		// The rows it holds run on unbroken for at least the scrollback plus the screen, so steps
		// that long can't jump past them. Find one row in the run, then narrow down to the first one
		// between it and a row known to be before it. Lines are only added between resets to 0, so
		// look up from the guess.
		let step = max(terminal.getTopVisibleRow() + terminal.rows, 1)
		var low = guess
		var high = guess + step
		if holds(guess) {
			low = 0
			high = guess
		} else {
			var steps = 0
			while !holds(high) {
				steps += 1
				if steps > 100_000 {
					logger.error("Couldn’t find the first line of the scrollback")
					return guess
				}
				low = high
				high += step
			}
		}
		while high - low > 1 {
			let middle = (low + high) / 2
			if holds(middle) {
				high = middle
			} else {
				low = middle
			}
		}
		return high
	}

	/// How many rows the lines `state` describes have moved up since, as lines were dropped from the
	/// top (a full scrollback taking new lines, or a resize trimming it). Nil if they aren't there
	/// any more: cleared, reset, rewrapped to a new width or on the other screen.
	private func rowsDropped(since state: LinesState, in terminal: Terminal) -> Int? {
		guard state.cols == terminal.cols,
					let anchor = state.anchor else {
			return nil
		}
		var row = min(anchor.row, terminal.getTopVisibleRow() + terminal.rows - 1)
		while row >= 0 && line(atRow: row) !== anchor.line {
			row -= 1
		}
		return row >= 0 ? anchor.row - row : nil
	}

	/// Brings `lines` up to date with the terminal and hands a copy to the delegate.
	private func updateLines(terminal: Terminal) {
		// Coming back from the other screen, its linesTop is the better guess.
		let guess = screenDidChange ? max(linesTop, otherScreenLines?.state.linesTop ?? 0) : linesTop
		linesTop = findLinesTop(near: guess, in: terminal)

		let topVisibleRow = terminal.getTopVisibleRow()
		let rowCount = topVisibleRow + terminal.rows
		var cursorLocation = terminal.getCursorLocation()
		cursorLocation.y += topVisibleRow
		let updateRange = terminal.getScrollInvariantUpdateRange()

		// Work out how the lines moved since the last update.
		var droppedRows = 0
		var redrawAll = needsFullRedraw
		// Rows from here down are redrawn whatever the update range says.
		var redrawFrom = rowCount
		if screenDidChange {
			// Switching to or from the alternate screen redraws the screen, and the update range mixes
			// rows of both. The normal screen's scrollback comes back as it was.
			screenDidChange = false
			if let dropped = rowsDropped(since: linesState, in: terminal) {
				// Back on the same screen already
				droppedRows = dropped
				redrawFrom = linesState.topVisibleRow - dropped
			} else {
				let current = (lines: lines, state: linesState)
				if let other = otherScreenLines,
					 let dropped = rowsDropped(since: other.state, in: terminal) {
					lines = other.lines
					linesState = other.state
					droppedRows = dropped
					redrawFrom = other.state.topVisibleRow - dropped
					otherScreenLines = current
				} else {
					redrawAll = true
					// Rows waiting to be redrawn in a new font or theme aren't worth keeping.
					if !needsFullRedraw && (current.state.anchor != nil || otherScreenLines == nil) {
						otherScreenLines = current
					}
				}
			}
		} else if linesState.anchor != nil {
			if let dropped = rowsDropped(since: linesState, in: terminal) {
				droppedRows = dropped
			} else {
				redrawAll = true
			}
		} else if linesState.cols == terminal.cols && linesTop >= linesState.linesTop {
			// No scrollback last time, so nothing to find. Any lines dropped since went through it.
			// (A new width rewraps every row, so that redraws them all.)
			droppedRows = linesTop - linesState.linesTop
		} else {
			redrawAll = true
		}

		var lastCursorLocation = linesState.cursorLocation
		lastCursorLocation.y -= droppedRows
		if !redrawAll && redrawFrom >= rowCount && droppedRows == 0 && updateRange == nil && cursorLocation == lastCursorLocation {
			// Nothing changed, nothing to do.
			return
		}
		terminal.clearUpdateRange()
		needsFullRedraw = false

		// Drop the rows that went off the top, then make it one row more than the terminal has, as
		// it has always been. That extra row below the last line stays blank, whatever was there.
		lines.removeFirst(min(droppedRows, lines.count))
		if lines.count > rowCount {
			lines.removeSubrange(rowCount...)
		}
		while lines.count <= rowCount {
			lines.append(AnyView(EmptyView()))
		}

		// Update lines that changed
		var linesToUpdate = Set<Int>()
		if redrawAll {
			linesToUpdate = Set(0..<rowCount)
		} else {
			if redrawFrom < rowCount {
				linesToUpdate.formUnion(max(redrawFrom, 0)..<rowCount)
			} else if let updateRange = updateRange {
				// A row is marked by where it was when it changed, and moves up with each line dropped
				// after that, so look as many rows further up as were dropped.
				linesToUpdate.formUnion(max(updateRange.startY - droppedRows, 0)...max(updateRange.endY, 0))
			}
			// The lines added at the bottom as others were dropped from the top
			linesToUpdate.formUnion(max(rowCount - droppedRows, 0)..<rowCount)
			if cursorLocation != lastCursorLocation {
				linesToUpdate.insert(cursorLocation.y)
				if lastCursorLocation.y >= 0 && lastCursorLocation.y < rowCount {
					linesToUpdate.insert(lastCursorLocation.y)
				}
			}
		}

		for i in linesToUpdate where i < rowCount {
			lines[i] = stringSupplier.attributedString(forRow: i, linesTop: linesTop)
		}

		let anchorRow = topVisibleRow - 1
		linesState = LinesState(topVisibleRow: topVisibleRow,
														cols: terminal.cols,
														linesTop: linesTop,
														cursorLocation: cursorLocation,
														anchor: line(atRow: anchorRow).map { (row: anchorRow, line: $0) })

		// Hand over a copy: the next update changes `lines` on this queue while main reads it.
		let snapshot = lines
		DispatchQueue.main.async { [droppedRows, linesTop] in
			self.shownLinesTop = linesTop
			self.delegate?.refresh(lines: snapshot, droppedRows: droppedRows)

			if !self.isVisible && !self.isDirty {
				self.isDirty = true
			}
		}
	}

	public func clearTerminal() {
		terminalQueue.async {
			guard let terminal = self.terminal else {
				return
			}

			// Resetting also turns off modes the running program turned on, which it still expects,
			// such as the bracketed paste that keeps pastes from running at a shell prompt.
			let bracketedPasteMode = terminal.bracketedPasteMode
			let applicationCursor = terminal.applicationCursor
			terminal.resetToInitialState()
			if bracketedPasteMode {
				terminal.feed(text: "\u{1b}[?2004h")
			}
			if applicationCursor {
				terminal.feed(text: "\u{1b}[?1h")
			}
			self.otherScreenLines = nil
			self.needsFullRedraw = true
		}

		// To trigger a redraw, update the screen size, then update it back.
		if let screenSize = screenSize {
			var newScreenSize = screenSize
			newScreenSize.cols -= 1
			self.subProcess?.screenSize = newScreenSize

			DispatchQueue.main.async {
				self.subProcess?.screenSize = screenSize
			}
		}
	}

	private func updateScreenSize() {
		if let screenSize = screenSize,
			 let terminal = terminal,
			 Int(screenSize.cols) != terminalSize.cols || Int(screenSize.rows) != terminalSize.rows {
			terminalSize = (Int(screenSize.cols), Int(screenSize.rows))

			// Resize on the terminal queue, which may be feeding or drawing the buffer right now. The
			// program hears of the new size after that's queued, so its redraw arrives after it too.
			terminalQueue.async {
				terminal.resize(cols: Int(screenSize.cols),
												rows: Int(screenSize.rows))
			}
			subProcess?.screenSize = screenSize

			if let error = subProcessFailureError {
				let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
				readInputStream(ColorBars.render(screenSize: screenSize, message: message))
			}
		}
	}

	private func updateTitle() {
		var newTitle: String? = nil
		if let title = title,
			 !title.isEmpty {
			newTitle = title
		}
		if let hostname = hostname {
			let user = self.user == NSUserName() ? nil : self.user
			let cleanedHostname = hostname.replacingOccurrences(of: #"\.local$"#, with: "", options: .regularExpression, range: hostname.startIndex..<hostname.endIndex)
			let hostString: String
			if isLocalhost {
				hostString = user ?? ""
			} else {
				hostString = "\(user ?? "")\(user == nil ? "" : "@")\(cleanedHostname)"
			}
			if !hostString.isEmpty {
				newTitle = "[\(hostString)] \(newTitle ?? "")"
			}
		}
		self.delegate?.titleDidChange(newTitle,
																	isDirty: isDirty,
																	hasBell: hasBell)
	}

	// MARK: - Object lifecycle

	deinit {
		updateTimer?.invalidate()
	}

}

extension TerminalController: TerminalDelegate {

	public func isProcessTrusted(source: Terminal) -> Bool { isLocalhost }

	public func send(source: Terminal, data: ArraySlice<UInt8>) {
		terminalQueue.async {
			self.write([UTF8Char](data))
		}
	}

	public func bell(source: Terminal) {
		DispatchQueue.main.async {
			// Throttle bell so it only rings a maximum of once a second.
			if self.lastBellDate == nil || self.lastBellDate! < Date(timeIntervalSinceNow: -1) {
				self.lastBellDate = Date()
				self.delegate?.activateBell()
			}

			if !self.isVisible && !self.hasBell {
				self.hasBell = true
			}
		}
	}

	public func bufferActivated(source: Terminal) {
		screenDidChange = true
	}

	public func showCursor(source: Terminal) {
		stringSupplier.cursorVisible = true
	}

	public func hideCursor(source: Terminal) {
		stringSupplier.cursorVisible = false
	}

	public func setTerminalTitle(source: Terminal, title: String) {
		self.title = title
		DispatchQueue.main.async {
			self.updateTitle()
		}
	}

	public func hostCurrentDirectoryUpdated(source: Terminal) {
		hostCurrentDocumentUpdated(source: source)
	}

	public func hostCurrentDocumentUpdated(source: Terminal) {
		let workingDirectory = source.hostCurrentDirectory
		let filePath = source.hostCurrentDocument ?? workingDirectory
		currentWorkingDirectory = nil
		currentFile = nil

		if let workingDirectory = workingDirectory,
			 let url = URL(string: workingDirectory),
			 url.isFileURL {
			hostname = url.host
			if isLocalhost {
				currentWorkingDirectory = url
			}
		}

		if let filePath = filePath,
			 let url = URL(string: filePath),
			 url.isFileURL {
			hostname = url.host
			if isLocalhost {
				currentFile = url
			}
		}

		DispatchQueue.main.async {
			self.delegate?.currentFileDidChange(self.currentFile ?? self.currentWorkingDirectory,
																					inWorkingDirectory: self.currentWorkingDirectory)
		}
	}

}

extension TerminalController: TerminalInputProtocol {

	public var applicationCursor: Bool { terminal?.applicationCursor ?? false }

	public var bracketedPasteMode: Bool { terminal?.bracketedPasteMode ?? false }

	public func receiveKeyboardInput(data: [UTF8Char]) {
		// Keys that send nothing, such as ctrl or the keyboard key, aren't typing.
		guard !data.isEmpty else {
			return
		}
		// Forward the data from the keyboard directly to the subprocess
		subProcess!.write(data: data)
		delegate?.didReceiveKeyboardInput()
	}

}

extension TerminalController: SubProcessDelegate {

	func subProcessDidConnect() {
		// Yay
	}

	func subProcess(didReceiveData data: [UTF8Char]) {
		// Simply forward the input stream down the VT100 processor. When it notices changes to the
		// screen, it should invoke our refresh delegate below.
		readInputStream(data)
	}

	func subProcess(didDisconnectWithError error: Error?) {
		if let error = error {
			delegate?.didReceiveError(error: error)
		} else {
			// This can be the user just typing an EOF (^D) to end the terminal session. However, it
			// can also happen because the process crashed for some reason. If it seems like the shell
			// exited gracefully, just close the tab.
			if (processLaunchDate ?? Date()) < Date(timeIntervalSinceNow: -3) {
				delegate?.close()
			}
		}

		// Write the termination message to the terminal.
		let processCompleted = String.localize("PROCESS_COMPLETED_TITLE", comment: "Title displayed when the terminal’s process has ended.")
		let cols = Int(subProcess?.screenSize.cols ?? 0)
		// Counted in columns: a Chinese title takes two per character.
		let messageLength = processCompleted.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) }) + 2
		let divider = String(repeating: "═", count: max((cols - messageLength) / 2, 0))
		let message = "\r\n\u{1b}[0;31m\(divider) \u{1b}[1;31m\(processCompleted)\u{1b}[0;31m \(divider)\u{1b}[m\r\n"
		readInputStream(message.data(using: .utf8)!)

		updateTimer?.invalidate()
		updateTimer = nil
		updateTimerFired()
	}

	func subProcess(didReceiveError error: Error) {
		delegate?.didReceiveError(error: error)
	}

}
