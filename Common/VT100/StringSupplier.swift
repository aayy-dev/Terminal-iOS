//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

fileprivate extension View {
	static func + (lhs: Self, rhs: some View) -> AnyView {
		AnyView(ViewBuilder.buildBlock(lhs, AnyView(rhs)))
	}
}

extension BufferLine {
	/// Whether cell `index` only holds the second half of the wide character before it. SwiftTerm
	/// leaves that cell empty with a width of 1, so read as is it would become an extra space.
	func isWideCharacterSpill(at index: Int) -> Bool {
		index > 0 && index < count && getWidth(index: index - 1) == 2 && self[index].getCharacter() == "\0"
	}
}

open class StringSupplier {

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

	/// `row` counts from the oldest line the terminal still holds, as getTopVisibleRow() does.
	/// getScrollInvariantLine(row:) counts from before the `linesTop` lines a full scrollback has
	/// dropped since.
	public func attributedString(forRow row: Int, linesTop: Int = 0) -> AnyView {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row + linesTop) else {
			return AnyView(EmptyView())
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()

		var lastAttribute = Attribute.empty
		var views = [AnyView]()
		var buffer = ""
		// A wide character gets a run of its own, covering its cell and the next one, which only
		// holds its second half, so the text after it stays on the grid.
		var bufferCells = 0
		var bufferIsWide = false
		var j = 0
		while j < terminal.cols {
			let data = line[j]
			let cells = line.isWideCharacterSpill(at: j + 1) ? 2 : 1
			let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y
				&& (j..<(j + cells)).contains(cursorPosition.x)

			if isCursor || cells == 2 || bufferIsWide || lastAttribute != data.attribute {
				// Finish up the last run by appending it to the attributed string, then reset for the
				// next run.
				views.append(text(buffer, cells: bufferCells, attribute: lastAttribute, isWide: bufferIsWide))
				lastAttribute = data.attribute
				buffer.removeAll()
				bufferCells = 0
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)
			bufferCells += cells
			bufferIsWide = cells == 2

			if isCursor {
				// We may need to insert a space for the cursor to show up.
				if buffer.isEmpty {
					buffer.append(" ")
				}

				views.append(text(buffer, cells: bufferCells, attribute: lastAttribute, isWide: bufferIsWide, isCursor: true))
				buffer.removeAll()
				bufferCells = 0
				bufferIsWide = false
			}
			j += cells
		}

		// Append the final run
		views.append(text(buffer, cells: bufferCells, attribute: lastAttribute, isWide: bufferIsWide))

		return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		})
	}

	private func text(_ run: String, cells: Int, attribute: Attribute, isWide: Bool = false, isCursor: Bool = false) -> AnyView {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		// As many columns as its cells, unless its characters need more: SwiftTerm gives some (emoji,
		// say) one cell, and squeezed into it they'd turn into "…".
		let columns = max(cells, run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) }))
		let width = CGFloat(columns) * (fontMetrics?.width ?? 0)

		let label = Text(run)
			// Text attributes
			.foregroundColor(Color(foreground ?? .white))
			.font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
			.underline(attribute.style.contains(.underline))
			.strikethrough(attribute.style.contains(.crossedOut))
			.tracking(0)
			// View attributes
			.allowsTightening(false)
			.lineLimit(1)

		if isWide {
			// A wide glyph (an emoji, say) can come out a little wider than its two cells. Let it
			// overflow them rather than turn into "…", and colour the two cells behind it.
			return AnyView(
				label
					.fixedSize(horizontal: true, vertical: false)
					.frame(width: width)
					.background(Color(background ?? .black))
					.fixedSize(horizontal: false, vertical: true)
			)
		}

		return AnyView(
			label
				.background(Color(background ?? .black))
				.frame(width: width)
				.fixedSize(horizontal: false, vertical: true)
		)
	}

}
