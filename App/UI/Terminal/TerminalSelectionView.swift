//
//  TerminalSelectionView.swift
//  NewTerm (iOS)
//
//  Created by aay on 15/10/2026.
//

import UIKit
import NewTermCommon

/// Native iOS text selection over the terminal: the system's handles, loupe and edit menu, mapped
/// onto the character grid. It sits inside the terminal's scroll view and covers all of its
/// content, so a selection scrolls with the text. It's read-only; typing stays with
/// TerminalKeyInput, which takes first responder back when the selection ends.
class TerminalSelectionView: UIView, UITextInput {

	weak var terminalController: TerminalController?

	/// Called with true when a selection appears and false when it goes away.
	var selectionActiveDidChange: ((Bool) -> Void)?
	/// Pastes into the terminal; the edit menu's Paste ends the selection and calls this.
	var pasteHandler: (() -> Void)?

	/// Grid geometry, kept current by the view controller.
	private(set) var rowCount = 0
	private(set) var cols = 0
	private(set) var cellSize = CGSize(width: 1, height: 1)
	private(set) var origin = CGPoint.zero

	private let interaction = UITextInteraction(for: .nonEditable)
	private var editMenuInteraction: AnyObject?

	/// While selecting, the keyboard stays hidden and the toolbar stays where it is: these are the
	/// typing input's own hidden-keyboard view and toolbar, so taking focus from it moves neither.
	var sharedInputView: UIView?
	var sharedInputAccessoryView: UIView?

	/// Goes up whenever the selection changes, so a delayed action can tell a selection started.
	private(set) var selectionChangeCount = 0

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		interaction.textInput = self
		addInteraction(interaction)
		if #available(iOS 16, *) {
			let editMenu = UIEditMenuInteraction(delegate: nil)
			addInteraction(editMenu)
			editMenuInteraction = editMenu
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func update(rowCount: Int, cols: Int, cellSize: CGSize, origin: CGPoint) {
		let changedWidth = cols != self.cols
		self.rowCount = rowCount
		self.cols = cols
		self.cellSize = cellSize
		self.origin = origin
		if changedWidth {
			// Positions are cells, so they no longer mean the same text after a resize.
			clearSelection()
		}
	}

	var hasSelection: Bool {
		guard let range = selectedTextRange as? GridRange else {
			return false
		}
		return !range.isEmpty
	}

	func selectionContains(_ location: CGPoint) -> Bool {
		guard let range = selectedTextRange else {
			return false
		}
		return selectionRects(for: range).contains { $0.rect.insetBy(dx: -8, dy: -8).contains(location) }
	}

	// MARK: - Selecting

	override var canBecomeFirstResponder: Bool { true }

	override var inputView: UIView? { sharedInputView }
	override var inputAccessoryView: UIView? { sharedInputAccessoryView }

	/// A plain tap is the view controller's: it shows the keyboard, or the edit menu on a selection.
	/// The text interaction's own tap takes first responder, which hides the keyboard. Only taps
	/// attached to this view: UIKit also asks it about its superviews' recognizers.
	override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		if let tap = gestureRecognizer as? UITapGestureRecognizer,
			 tap.view === self,
			 tap.numberOfTapsRequired == 1,
			 tap.numberOfTouchesRequired == 1 {
			return false
		}
		return super.gestureRecognizerShouldBegin(gestureRecognizer)
	}

	override func resignFirstResponder() -> Bool {
		let result = super.resignFirstResponder()
		if result {
			clearSelection()
		}
		return result
	}

	/// Selects everything, scrollback included, and offers the edit menu.
	override func selectAll(_ sender: Any?) {
		guard rowCount > 0 else {
			return
		}
		_ = becomeFirstResponder()
		setSelection(GridRange(from: position(TerminalTextPoint(row: 0, col: 0)),
													 to: position(lastPoint)))
		showEditMenu()
	}

	func clearSelection() {
		guard selectedTextRange != nil else {
			return
		}
		setSelection(nil)
	}

	/// Moves the selection `delta` rows, to keep it on its text when rows go off the top of a full
	/// scrollback. If its text went with them, the selection ends.
	func moveRows(by delta: Int) {
		guard let range = selectedTextRange as? GridRange, !range.isEmpty else {
			return
		}
		let end = TerminalTextPoint(row: range.end.point.row + delta, col: range.end.point.col)
		guard end.row >= 0 else {
			clearSelection()
			return
		}
		var start = range.start.point
		start.row += delta
		if start.row < 0 {
			start = TerminalTextPoint(row: 0, col: 0)
		}
		setSelection(GridRange(from: GridPosition(start), to: GridPosition(end)))
	}

	/// Changes the selection from code, telling the text interaction so its handles follow.
	private func setSelection(_ range: GridRange?) {
		inputDelegate?.selectionWillChange(self)
		isSettingSelection = true
		selectedTextRange = range
		isSettingSelection = false
		inputDelegate?.selectionDidChange(self)
	}
	private var isSettingSelection = false

	private func showEditMenu() {
		guard let scrollView = superview as? UIScrollView else {
			return
		}
		let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
		showEditMenu(at: CGPoint(x: visible.midX, y: visible.minY + visible.height / 3))
	}

	/// Shows the edit menu at a point in this view, as a tap on the selection does.
	func showEditMenu(at point: CGPoint) {
		if #available(iOS 16, *), let editMenu = editMenuInteraction as? UIEditMenuInteraction {
			editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
		} else {
			UIMenuController.shared.showMenu(from: self, rect: CGRect(origin: point, size: .zero))
		}
	}

	// MARK: - Edit menu

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		switch action {
		case #selector(copy(_:)):
			return hasSelection
		case #selector(selectAll(_:)):
			return rowCount > 0
		case #selector(paste(_:)):
			return pasteHandler != nil && (UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs)
		case #selector(cut(_:)), #selector(delete(_:)),
				 #selector(select(_:)), #selector(toggleBoldface(_:)), #selector(toggleItalics(_:)),
				 #selector(toggleUnderline(_:)):
			return false
		default:
			return super.canPerformAction(action, withSender: sender)
		}
	}

	override func copy(_ sender: Any?) {
		guard let range = selectedTextRange, let text = text(in: range) else {
			return
		}
		UIPasteboard.general.string = text
	}

	override func paste(_ sender: Any?) {
		clearSelection()
		pasteHandler?()
	}

	// MARK: - Geometry

	private var lastPoint: TerminalTextPoint {
		TerminalTextPoint(row: max(rowCount - 1, 0), col: cols)
	}

	private func clamp(_ point: TerminalTextPoint) -> TerminalTextPoint {
		if point.row < 0 {
			return TerminalTextPoint(row: 0, col: 0)
		}
		if point.row >= rowCount {
			return lastPoint
		}
		return TerminalTextPoint(row: point.row, col: min(max(point.col, 0), cols))
	}

	private func x(_ col: Int) -> CGFloat { origin.x + CGFloat(col) * cellSize.width }
	private func y(_ row: Int) -> CGFloat { origin.y + CGFloat(row) * cellSize.height }

	private func point(at location: CGPoint) -> TerminalTextPoint {
		let row = Int(floor((location.y - origin.y) / cellSize.height))
		let col = Int(((location.x - origin.x) / cellSize.width).rounded())
		return clamp(TerminalTextPoint(row: row, col: col))
	}

	private func cell(at location: CGPoint) -> TerminalTextPoint {
		let row = Int(floor((location.y - origin.y) / cellSize.height))
		let col = Int(floor((location.x - origin.x) / cellSize.width))
		return clamp(TerminalTextPoint(row: row, col: min(col, cols - 1)))
	}

	private func position(_ point: TerminalTextPoint) -> GridPosition { GridPosition(clamp(point)) }

	private func linear(_ point: TerminalTextPoint) -> Int { point.row * (cols + 1) + point.col }

	private func point(linear index: Int) -> TerminalTextPoint {
		let stride = cols + 1
		let index = min(max(index, 0), linear(lastPoint))
		return TerminalTextPoint(row: index / stride, col: index % stride)
	}

	// MARK: - UITextInput: text

	var hasText: Bool { rowCount > 0 }
	func insertText(_ text: String) {}
	func deleteBackward() {}

	func text(in range: UITextRange) -> String? {
		guard let range = range as? GridRange, let terminalController = terminalController else {
			return nil
		}
		return terminalController.text(from: range.start.point, to: range.end.point)
	}

	func replace(_ range: UITextRange, withText text: String) {}

	var selectedTextRange: UITextRange? {
		didSet {
			selectionChangeCount += 1
			let wasActive = (oldValue as? GridRange).map { !$0.isEmpty } ?? false
			if hasSelection != wasActive {
				selectionActiveDidChange?(hasSelection)
			}
			if hasSelection && !isFirstResponder {
				_ = becomeFirstResponder()
			}
			if !isSettingSelection {
				scrollToMovedEnd(from: oldValue as? GridRange)
			}
		}
	}

	var markedTextRange: UITextRange? { nil }
	var markedTextStyle: [NSAttributedString.Key: Any]?
	func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
	func unmarkText() {}

	weak var inputDelegate: UITextInputDelegate?
	lazy var tokenizer: UITextInputTokenizer = TerminalTokenizer(selectionView: self)

	// MARK: - UITextInput: positions

	var beginningOfDocument: UITextPosition { position(TerminalTextPoint(row: 0, col: 0)) }
	var endOfDocument: UITextPosition { position(lastPoint) }

	func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
		guard let from = fromPosition as? GridPosition, let to = toPosition as? GridPosition else {
			return nil
		}
		return GridRange(from: from, to: to)
	}

	func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
		guard let position = position as? GridPosition else {
			return nil
		}
		return GridPosition(point(linear: linear(position.point) + offset))
	}

	func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
		guard let position = position as? GridPosition else {
			return nil
		}
		var point = position.point
		switch direction {
		case .right: return self.position(from: position, offset: offset)
		case .left:  return self.position(from: position, offset: -offset)
		case .down:  point.row += offset
		case .up:    point.row -= offset
		@unknown default: return nil
		}
		return self.position(point)
	}

	func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
		guard let a = (position as? GridPosition)?.point, let b = (other as? GridPosition)?.point else {
			return .orderedSame
		}
		return a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
	}

	func offset(from: UITextPosition, to: UITextPosition) -> Int {
		guard let from = from as? GridPosition, let to = to as? GridPosition else {
			return 0
		}
		return linear(to.point) - linear(from.point)
	}

	func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
		switch direction {
		case .left, .up: return range.start
		default:         return range.end
		}
	}

	func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
		guard let position = position as? GridPosition,
					let other = self.position(from: position, in: direction, offset: 1) else {
			return nil
		}
		return textRange(from: position, to: other)
	}

	func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
	func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

	// MARK: - UITextInput: geometry

	func firstRect(for range: UITextRange) -> CGRect {
		guard let range = range as? GridRange else {
			return .zero
		}
		let start = range.start.point, end = range.end.point
		let endCol = end.row == start.row ? end.col : cols
		return CGRect(x: x(start.col), y: y(start.row), width: x(endCol) - x(start.col), height: cellSize.height)
	}

	func caretRect(for position: UITextPosition) -> CGRect {
		guard let point = (position as? GridPosition)?.point else {
			return .zero
		}
		return CGRect(x: x(point.col), y: y(point.row), width: 2, height: cellSize.height)
	}

	func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
		guard let range = range as? GridRange, !range.isEmpty else {
			return []
		}
		let start = range.start.point, end = range.end.point
		return (start.row...end.row).map { row in
			let first = row == start.row ? start.col : 0
			let last = row == end.row ? end.col : cols
			return GridSelectionRect(rect: CGRect(x: x(first), y: y(row), width: x(last) - x(first), height: cellSize.height),
															 containsStart: row == start.row,
															 containsEnd: row == end.row)
		}
	}

	func closestPosition(to point: CGPoint) -> UITextPosition? { position(self.point(at: point)) }

	func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
		guard let range = range as? GridRange else {
			return nil
		}
		let found = self.point(at: point)
		return GridPosition(min(max(found, range.start.point), range.end.point))
	}

	func characterRange(at point: CGPoint) -> UITextRange? {
		let cell = self.cell(at: point)
		return GridRange(from: position(cell), to: position(TerminalTextPoint(row: cell.row, col: cell.col + 1)))
	}

	// MARK: - Scrolling while dragging a handle

	/// Keeps the end of the selection that moved on screen, so dragging a handle to the top or
	/// bottom edge scrolls on through the text.
	private func scrollToMovedEnd(from old: GridRange?) {
		guard let new = selectedTextRange as? GridRange, let old = old, !new.isEmpty,
					let scrollView = superview as? UIScrollView else {
			return
		}
		let moved: TerminalTextPoint
		if new.start.point != old.start.point && new.end.point == old.end.point {
			moved = new.start.point
		} else if new.end.point != old.end.point && new.start.point == old.start.point {
			moved = new.end.point
		} else {
			return
		}
		let rect = CGRect(x: 0, y: y(moved.row), width: 1, height: cellSize.height)
		scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -cellSize.height), animated: false)
	}

	// MARK: - Words and lines

	/// What a double tap selects within a row: a run of word characters, a run of blank space, or a
	/// single punctuation mark. A word runs up to whitespace, quotes and brackets, so a double tap
	/// takes a whole path, URL or flag rather than stopping at every slash or dot.
	private enum CellClass { case word, space, punctuation }

	private static let wordBreaks = Set<Character>("\"'`()[]{}<>|;,")

	private static func cellClass(_ character: Character) -> CellClass {
		if character.isWhitespace {
			return .space
		}
		return wordBreaks.contains(character) ? .punctuation : .word
	}

	private func range(row: Int, from first: Int, to last: Int) -> GridRange {
		GridRange(from: position(TerminalTextPoint(row: row, col: first)),
							to: position(TerminalTextPoint(row: row, col: last)))
	}

	fileprivate var documentRange: GridRange {
		GridRange(from: position(TerminalTextPoint(row: 0, col: 0)), to: position(lastPoint))
	}

	fileprivate func characterRange(at point: TerminalTextPoint) -> GridRange {
		let col = min(point.col, max(cols - 1, 0))
		return range(row: point.row, from: col, to: col + 1)
	}

	/// The run of same-class cells at `point` (or just before it, at the end of a row).
	fileprivate func wordRange(around point: TerminalTextPoint) -> GridRange? {
		guard let cells = terminalController?.cells(inRow: point.row), !cells.isEmpty else {
			return nil
		}
		let col = min(point.col, cells.count - 1)
		let kind = Self.cellClass(cells[col])
		var first = col, last = col
		if kind != .punctuation {
			while first > 0 && Self.cellClass(cells[first - 1]) == kind {
				first -= 1
			}
			while last + 1 < cells.count && Self.cellClass(cells[last + 1]) == kind {
				last += 1
			}
		}
		return range(row: point.row, from: first, to: last + 1)
	}

	fileprivate func isInWord(_ point: TerminalTextPoint) -> Bool {
		guard let cells = terminalController?.cells(inRow: point.row), !cells.isEmpty else {
			return false
		}
		return Self.cellClass(cells[min(point.col, cells.count - 1)]) == .word
	}

	/// Word boundaries are the edges of those runs, plus the start and end of every row.
	fileprivate func isWordBoundary(_ point: TerminalTextPoint) -> Bool {
		if point.col <= 0 || point.col >= cols {
			return true
		}
		guard let cells = terminalController?.cells(inRow: point.row), point.col < cells.count else {
			return true
		}
		let before = Self.cellClass(cells[point.col - 1])
		return before != Self.cellClass(cells[point.col]) || before == .punctuation
	}

	/// The next word boundary from `point`, moving forward or backward through the rows.
	fileprivate func wordBoundary(from point: TerminalTextPoint, forward: Bool) -> TerminalTextPoint {
		var point = point
		repeat {
			if forward {
				if point.col >= cols {
					guard point.row + 1 < rowCount else {
						return point
					}
					point = TerminalTextPoint(row: point.row + 1, col: 0)
				} else {
					point.col += 1
				}
			} else {
				if point.col <= 0 {
					guard point.row > 0 else {
						return point
					}
					point = TerminalTextPoint(row: point.row - 1, col: cols)
				} else {
					point.col -= 1
				}
			}
		} while !isWordBoundary(point)
		return point
	}

	/// The whole line around `point`, following rows the terminal wrapped.
	fileprivate func lineRange(around point: TerminalTextPoint) -> GridRange {
		let rows = terminalController?.logicalLineRows(containing: point.row) ?? point.row...point.row
		return GridRange(from: position(TerminalTextPoint(row: rows.lowerBound, col: 0)),
										 to: position(TerminalTextPoint(row: rows.upperBound, col: cols)))
	}

}

// MARK: - Positions, ranges and rects

final class GridPosition: UITextPosition {
	let point: TerminalTextPoint
	init(_ point: TerminalTextPoint) {
		self.point = point
		super.init()
	}
}

final class GridRange: UITextRange {
	private let from: GridPosition
	private let to: GridPosition

	init(from: GridPosition, to: GridPosition) {
		if to.point < from.point {
			self.from = to
			self.to = from
		} else {
			self.from = from
			self.to = to
		}
		super.init()
	}

	override var start: GridPosition { from }
	override var end: GridPosition { to }
	override var isEmpty: Bool { from.point == to.point }
}

private final class GridSelectionRect: UITextSelectionRect {
	private let _rect: CGRect
	private let _containsStart: Bool
	private let _containsEnd: Bool

	init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
		_rect = rect
		_containsStart = containsStart
		_containsEnd = containsEnd
		super.init()
	}

	override var rect: CGRect { _rect }
	override var writingDirection: NSWritingDirection { .leftToRight }
	override var containsStart: Bool { _containsStart }
	override var containsEnd: Bool { _containsEnd }
	override var isVertical: Bool { false }
}

// MARK: - Tokenizer

/// Answers every boundary question from the grid. UITextInputStringTokenizer can't be used, even
/// as a fallback: it assumes text(in:) and position offsets line up character for character, which
/// isn't true here (rows are padded cells, and copied text is trimmed and joins wrapped rows).
private final class TerminalTokenizer: NSObject, UITextInputTokenizer {
	private weak var selectionView: TerminalSelectionView?

	init(selectionView: TerminalSelectionView) {
		self.selectionView = selectionView
		super.init()
	}

	private func isForward(_ direction: UITextDirection) -> Bool {
		[UITextStorageDirection.forward.rawValue, UITextLayoutDirection.right.rawValue, UITextLayoutDirection.down.rawValue]
			.contains(direction.rawValue)
	}

	func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextRange? {
		guard let view = selectionView, let point = (position as? GridPosition)?.point else {
			return nil
		}
		switch granularity {
		case .character:                   return view.characterRange(at: point)
		case .word:                        return view.wordRange(around: point)
		case .sentence, .line, .paragraph: return view.lineRange(around: point)
		case .document:                    return view.documentRange
		@unknown default:                  return nil
		}
	}

	func isPosition(_ position: UITextPosition, atBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
		guard let view = selectionView, let point = (position as? GridPosition)?.point else {
			return false
		}
		switch granularity {
		case .character:
			return true
		case .word:
			return view.isWordBoundary(point)
		case .sentence, .line, .paragraph:
			let line = view.lineRange(around: point)
			return point == line.start.point || point == line.end.point
		case .document:
			return point == view.documentRange.start.point || point == view.documentRange.end.point
		@unknown default:
			return false
		}
	}

	func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition? {
		guard let view = selectionView, let point = (position as? GridPosition)?.point else {
			return nil
		}
		let forward = isForward(direction)
		switch granularity {
		case .character:
			return view.position(from: position, offset: forward ? 1 : -1)
		case .word:
			return GridPosition(view.wordBoundary(from: point, forward: forward))
		case .sentence, .line, .paragraph:
			let line = view.lineRange(around: point)
			let target = forward ? line.end.point : line.start.point
			if target != point {
				return GridPosition(target)
			}
			// Already at the edge of this line: go to the matching edge of the next or previous one.
			let neighbour = TerminalTextPoint(row: forward ? point.row + 1 : point.row - 1, col: 0)
			guard neighbour.row >= 0 && neighbour.row < view.rowCount else {
				return position
			}
			let next = view.lineRange(around: neighbour)
			return forward ? next.end : next.start
		case .document:
			return forward ? view.documentRange.end : view.documentRange.start
		@unknown default:
			return nil
		}
	}

	func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
		guard let view = selectionView, let point = (position as? GridPosition)?.point else {
			return false
		}
		switch granularity {
		case .word:
			return view.isInWord(point)
		default:
			return true
		}
	}
}
