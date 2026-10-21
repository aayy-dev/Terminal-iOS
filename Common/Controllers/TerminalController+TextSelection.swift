//
//  TerminalController+TextSelection.swift
//  NewTerm Common
//
//  Created by aay on 15/10/2026.
//

import Foundation
import SwiftTerm

/// A cell in the terminal, counted from the start of scrollback: the same rows as the lines the
/// terminal view shows. `col` may equal the column count, meaning the end of the row.
public struct TerminalTextPoint: Comparable, Hashable {
	public var row: Int
	public var col: Int

	public init(row: Int, col: Int) {
		self.row = row
		self.col = col
	}

	public static func < (lhs: Self, rhs: Self) -> Bool {
		(lhs.row, lhs.col) < (rhs.row, rhs.col)
	}
}

extension TerminalController {

	/// Rows (scrollback plus screen) and columns of the text the terminal holds.
	public var textGridSize: (rows: Int, cols: Int) {
		terminalQueue.sync {
			guard let terminal = terminal else {
				return (0, 0)
			}
			return (terminal.getTopVisibleRow() + terminal.rows, terminal.cols)
		}
	}

	/// The line in `row`, counting rows as the view last showed them. `linesTop` is shownLinesTop,
	/// read on main. Terminal queue only.
	private func shownLine(atRow row: Int, linesTop: Int) -> BufferLine? {
		terminal?.getScrollInvariantLine(row: row + linesTop)
	}

	/// The characters of a row, one per cell, for finding word boundaries. The cell a wide
	/// character spills into repeats that character, so it counts as part of the same word.
	public func cells(inRow row: Int) -> [Character] {
		let linesTop = shownLinesTop
		return terminalQueue.sync {
			guard let line = shownLine(atRow: row, linesTop: linesTop) else {
				return []
			}
			var cells = [Character]()
			cells.reserveCapacity(line.count)
			for i in 0..<line.count {
				if line.isWideCharacterSpill(at: i), let previous = cells.last {
					cells.append(previous)
				} else {
					let character = line[i].getCharacter()
					cells.append(character == "\0" ? " " : character)
				}
			}
			return cells
		}
	}

	/// The text between two points as it should be copied: rows the terminal wrapped because they
	/// ran past the edge are joined without a line break, spaces at the end of each line are
	/// dropped, and so are blank lines at the end.
	public func text(from start: TerminalTextPoint, to end: TerminalTextPoint) -> String {
		let linesTop = shownLinesTop
		return terminalQueue.sync {
			guard terminal != nil, start < end else {
				return ""
			}
			var lines = [String]()
			var current = ""
			var previous: BufferLine?
			for row in start.row...end.row {
				guard let line = shownLine(atRow: row, linesTop: linesTop) else {
					continue
				}
				if row > start.row && !Self.isWrapped(line, after: previous) {
					lines.append(Self.trimmingTrailingSpaces(current))
					current = ""
				}
				let first = row == start.row ? start.col : 0
				let last = row == end.row ? end.col : line.count
				current += Self.string(line, from: first, to: last)
				previous = line
			}
			lines.append(Self.trimmingTrailingSpaces(current))
			while lines.count > 1 && lines.last?.isEmpty == true {
				lines.removeLast()
			}
			return lines.joined(separator: "\n")
		}
	}

	/// The first and last rows of the line containing `row`, following rows the terminal wrapped.
	public func logicalLineRows(containing row: Int) -> ClosedRange<Int> {
		let linesTop = shownLinesTop
		return terminalQueue.sync {
			guard shownLine(atRow: row, linesTop: linesTop) != nil else {
				return row...row
			}
			var first = row
			while first > 0,
						let line = shownLine(atRow: first, linesTop: linesTop),
						Self.isWrapped(line, after: shownLine(atRow: first - 1, linesTop: linesTop)) {
				first -= 1
			}
			var last = row
			while let next = shownLine(atRow: last + 1, linesTop: linesTop),
						Self.isWrapped(next, after: shownLine(atRow: last, linesTop: linesTop)) {
				last += 1
			}
			return first...last
		}
	}

	// MARK: - Helpers

	/// Whether `line` continues the row above because the text ran past the edge. SwiftTerm keeps
	/// this in BufferLine.isWrapped, which isn't public, so read it by reflection. If that ever stops
	/// working, fall back to treating a row as wrapped when the row above is filled to the last column.
	private static func isWrapped(_ line: BufferLine, after previous: BufferLine?) -> Bool {
		if let flag = Mirror(reflecting: line).children.first(where: { $0.label == "isWrapped" })?.value as? Bool {
			return flag
		}
		guard let previous = previous, previous.count > 0 else {
			return false
		}
		return previous[previous.count - 1].getCharacter() != "\0"
	}

	/// Cells `start..<end` of a line. Empty cells become spaces, and the cell a wide character
	/// spills into is skipped so it doesn't turn into an extra space.
	private static func string(_ line: BufferLine, from start: Int, to end: Int) -> String {
		var result = ""
		let end = min(end, line.count)
		var i = max(start, 0)
		while i < end {
			if !line.isWideCharacterSpill(at: i) {
				let character = line[i].getCharacter()
				result.append(character == "\0" ? " " : character)
			}
			i += 1
		}
		return result
	}

	private static func trimmingTrailingSpaces(_ string: String) -> String {
		var string = string
		while string.last == " " {
			string.removeLast()
		}
		return string
	}

}
