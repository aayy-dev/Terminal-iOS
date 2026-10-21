//
//  TerminalView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 5/4/2022.
//

import SwiftUI
import SwiftUIX
import SwiftTerm
import NewTermCommon

class TerminalState: ObservableObject {
	@Published var lines = [AnyView]()
	@Published var fontMetrics = FontMetrics(font: AppFont(), fontSize: 12)
	@Published var colorMap = ColorMap(theme: AppTheme())
	@Published var isSplitViewResizing = false
	/// Whether new output scrolls the terminal to the bottom: it does while the user hasn't
	/// scrolled up from there. Read when output arrives, so changing it needn't redraw anything.
	var isFollowingOutput = true
}

struct TerminalView: View {
	static let horizontalSpacing: CGFloat = isBigDevice ? 3 : 0
	static let verticalSpacing: CGFloat = isBigDevice ? 2 : 0

	@EnvironmentObject private var state: TerminalState

	var body: some View {
		let view = ScrollViewReader { scrollView in
			ScrollView(.vertical, showsIndicators: true) {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(zip(state.lines, state.lines.indices)), id: \.1) { line, i in
						line
							.drawingGroup(opaque: true)
							.id(i)
					}
				}
					.padding(.vertical, Self.verticalSpacing)
					.padding(.horizontal, Self.horizontalSpacing)
					.background(Color(state.colorMap.background))
			}
				.background(Color(state.colorMap.background))
				.onChange(of: state.lines.indices.last, perform: { _ in
					if state.isFollowingOutput {
						scrollView.scrollTo(state.lines.indices.last, anchor: .bottom)
					}
				})
		}
			.opacity(state.isSplitViewResizing ? 0.6 : 1)
			.animation(.linear(duration: 0.1), value: state.isSplitViewResizing)

		if #available(iOS 15, *) {
			return view
				.accessibilityTextContentType(.console)
		} else {
			return view
		}
	}
}

class TerminalHostingView: UIHostingView<AnyView> {
	init(state: TerminalState) {
		let view = TerminalView()
			.environmentObject(state)
		super.init(rootView: AnyView(view))
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	required init(rootView: AnyView) {
		fatalError("init(rootView:) has not been implemented")
	}
}

struct TerminalSampleView: View {
	private class TerminalSampleViewDelegate: NSObject, TerminalDelegate {
		func send(source: Terminal, data: ArraySlice<UInt8>) {}
	}

	/// The sample terminal. The settings page around it builds a new TerminalSampleView whenever a
	/// preference changes, so this is kept once for the life of the view.
	private class Sample: ObservableObject {
		let state = TerminalState()
		private let terminal: Terminal
		private let stringSupplier = StringSupplier()
		private let delegate = TerminalSampleViewDelegate()
		private var size = CGSize.zero

		init() {
			let options = TerminalOptions(cols: 80,
																		rows: 25,
																		termName: "xterm-256color",
																		scrollback: 100)
			terminal = Terminal(delegate: delegate, options: options)
			stringSupplier.terminal = terminal

			if let colorTest = try? Data(contentsOf: Bundle.main.url(forResource: "colortest", withExtension: "txt")!) {
				terminal.feed(byteArray: [UTF8Char](colorTest))
			}
		}

		func update(fontMetrics: FontMetrics, colorMap: ColorMap, size: CGSize? = nil) {
			if let size = size {
				self.size = size
			}
			stringSupplier.fontMetrics = fontMetrics
			stringSupplier.colorMap = colorMap
			// The space around the rows takes its colour from the state.
			state.fontMetrics = fontMetrics
			state.colorMap = colorMap

			// Determine the screen size based on the font size
			// TODO: Calculate the exact number of lines we need from the buffer
			let glyphWidth = fontMetrics.boundingBox.width
			if glyphWidth > 0 && self.size.width > 0 {
				terminal.resize(cols: Int(self.size.width / glyphWidth),
												rows: 32)
			}

			state.lines = Array(0...(terminal.rows + terminal.getTopVisibleRow()))
				.map { stringSupplier.attributedString(forRow: $0) }
		}
	}

	let fontMetrics: FontMetrics
	let colorMap: ColorMap

	@StateObject private var sample = Sample()

	init(fontMetrics: FontMetrics = FontMetrics(font: AppFont(), fontSize: 12),
			 colorMap: ColorMap = ColorMap(theme: AppTheme())) {
		self.fontMetrics = fontMetrics
		self.colorMap = colorMap
	}

	var body: some View {
		TerminalView()
			.environmentObject(sample.state)
			.onChange(of: colorMap, perform: { sample.update(fontMetrics: fontMetrics, colorMap: $0) })
			.onChange(of: fontMetrics, perform: { sample.update(fontMetrics: $0, colorMap: colorMap) })
			.onAppearAndChangeOfFrame(perform: { size in
				sample.update(fontMetrics: fontMetrics, colorMap: colorMap, size: size)
			})
	}
}

struct TerminalView_Previews: PreviewProvider {
	static var previews: some View {
		TerminalSampleView()
			.preferredColorScheme(.dark)
	}
}
