//
//  KeyboardToolbarView.swift
//  NewTerm (iOS)
//
//  Created by Chris Harper on 11/21/21.
//

import SwiftUI
import NewTermCommon
import SwiftUIX

fileprivate struct Key {
	var label: String
	var glyph: String?
	var imageName: String?
	var preferredStyle: KeyboardButtonStyle?
	var isToggle = false
	var halfHeight = false
	var widthRatio: CGFloat?
	var keyRepeat: Bool?
	/// An action rather than a key that types something. On iPhone these are plain icons.
	var isAction = false
	/// On iPhone, show the glyph instead of the symbol, where the symbol isn't recognisable alone.
	var compactText = false
}

enum Toolbar: CaseIterable {
	case primary, padPrimaryLeading, padPrimaryTrailing

	var keys: [ToolbarKey] {
		switch self {
		case .primary:
			return [
				.control, .tab, .escape, .fn,
				.variableSpace(id: 0),
				.arrows,
				.variableSpace(id: 1),
				.selectAll, .paste, .keyboard
			]

		case .padPrimaryLeading:
			return [.control, .tab, .escape, .fn, .selectAll, .paste, .keyboard]

		case .padPrimaryTrailing:
			return [.arrows]
		}
	}
}

enum ToolbarKey: Hashable {
	// Special
	case fixedSpace(id: Int)
	case variableSpace(id: Int)
	case arrows
	// Primary - leading
	case control, escape, tab, fn
	// Primary - arrows
	case up, down, left, right
	// Navigation, typed with fn and an arrow key
	case home, end, pageUp, pageDown
	// Extras
	case delete, selectAll, paste, keyboard
	// Fn keys, typed with fn and a number key
	case fnKey(index: Int)

	/// What an arrow key types while fn is on.
	var functionKey: ToolbarKey {
		switch self {
		case .left:  return .home
		case .right: return .end
		case .up:    return .pageUp
		case .down:  return .pageDown
		default:     return self
		}
	}

	fileprivate var key: Key {
		switch self {
		// Special
		case .fixedSpace, .variableSpace, .arrows:
			return Key(label: "")

		// Primary - leading
		case .control:  return Key(label: .localize("Control"),
															 glyph: .localize("Ctrl"),
															 imageName: "control",
															 isToggle: true)
		case .escape:   return Key(label: .localize("Escape"),
															 glyph: .localize("Esc"),
															 imageName: "escape",
															 compactText: true)
		case .tab:      return Key(label: .localize("Tab"),
															 imageName: "arrow.right.to.line.alt")
		case .fn:       return Key(label: .localize("Function"),
															 glyph: .localize("Fn"),
															 imageName: "fn",
															 isToggle: true)
		// Primary - arrows
		case .up:       return Key(label: .localize("Up"),
															 imageName: "arrow.up",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .down:     return Key(label: .localize("Down"),
															 imageName: "arrow.down",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .left:     return Key(label: .localize("Left"),
															 imageName: "arrow.left",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .right:    return Key(label: .localize("Right"),
															 imageName: "arrow.right",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		// Navigation
		case .home:     return Key(label: .localize("Home"),
															 imageName: "arrow.left.to.line",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .end:      return Key(label: .localize("End"),
															 imageName: "arrow.right.to.line",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .pageUp:   return Key(label: .localize("Page Up"),
															 glyph: .localize("PgUp"),
															 imageName: "arrow.up.to.line",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .pageDown: return Key(label: .localize("Page Down"),
															 glyph: .localize("PgDn"),
															 imageName: "arrow.down.to.line",
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)

		// Extras
		case .delete:   return Key(label: .localize("Delete Forward"),
															 glyph: .localize("Del"),
															 imageName: "delete.right",
															 preferredStyle: .icons,
															 widthRatio: 1)
		case .selectAll: return Key(label: .localize("Select All"),
															 glyph: .localize("all"),
															 imageName: "selection.pin.in.out",
															 preferredStyle: .icons,
															 widthRatio: 1,
															 isAction: true)
		case .paste:    return Key(label: .localize("Paste"),
															 imageName: "doc.on.clipboard",
															 preferredStyle: .icons,
															 widthRatio: 1,
															 isAction: true)
		case .keyboard: return Key(label: .localize("Show or Hide Keyboard"),
															 glyph: .localize("kb"),
															 imageName: "keyboard",
															 preferredStyle: .icons,
															 widthRatio: 1,
															 isAction: true)

		// Fn keys
		case .fnKey(let index):
			return Key(label: "F\(index)",
								 preferredStyle: .text,
								 widthRatio: 1)
		}
	}
}

protocol KeyboardToolbarViewDelegate: AnyObject {
	func keyboardToolbarDidPressKey(_ key: ToolbarKey)
	func keyboardToolbarDidBeginPressingKey(_ key: ToolbarKey)
	func keyboardToolbarDidEndPressingKey(_ key: ToolbarKey)
}

class KeyboardToolbarViewState: ObservableObject {
	@Published var toggledKeys = Set<ToolbarKey>()
}

/// An SF Symbol, or text on iOS versions that don't have it.
fileprivate struct KeyIcon: View {
	let systemName: String?
	let fallback: String

	var body: some View {
		if let systemName = systemName,
			 UIImage(systemName: systemName) != nil {
			Image(systemName: systemName)
		} else {
			Text(fallback.localizedLowercase)
		}
	}
}

struct KeyboardToolbarKeyStack: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	let toolbar: Toolbar
	var arrowsStyle: KeyboardArrowsStyle?
	/// On iPhone, the width of each key. Keys there show only their icon, like iSH's toolbar.
	var compactKeyWidth: CGFloat?

	@EnvironmentObject var state: KeyboardToolbarViewState

	@ObservedObject private var preferences = Preferences.shared

	private var isCompact: Bool { compactKeyWidth != nil }

	var body: some View {
		HStack(alignment: .center, spacing: isCompact ? KeyboardToolbarView.compactSpacing : 5) {
			ForEach(toolbar.keys, id: \.self) { key in
				switch key {
				case .fixedSpace:    EmptyView()
				case .variableSpace: Spacer(minLength: 0)
				case .arrows:        arrowsView
				default:             button(for: key)
				}
			}
		}
	}

	@ViewBuilder
	func button(for baseKey: ToolbarKey, halfHeight: Bool = false) -> some View {
		// While fn is on, the arrow keys are Home, End, Page Up and Page Down.
		let key = state.toggledKeys.contains(.fn) ? baseKey.functionKey : baseKey
		let button = Button {
			UIDevice.current.playInputClick()

			if key.key.isToggle {
				if state.toggledKeys.contains(key) {
					state.toggledKeys.remove(key)
				} else {
					state.toggledKeys.insert(key)
				}
			}

			delegate?.keyboardToolbarDidPressKey(key)
		} label: {
			label(for: key)
		}
			.buttonStyle(.keyboardKey(selected: state.toggledKeys.contains(key),
																hasShadow: true,
																halfHeight: halfHeight,
																widthRatio: key.key.widthRatio,
																compactWidth: compactKeyWidth,
																isPlain: isCompact && key.key.isAction))

		if KeyboardPreferences.isKeyRepeatEnabled {
			button
				.onLongPressGesture(minimumDuration: KeyboardPreferences.keyRepeatDelay,
														perform: {},
														onPressingChanged: { pressing in
					if pressing {
						delegate?.keyboardToolbarDidBeginPressingKey(key)
					} else {
						delegate?.keyboardToolbarDidEndPressingKey(key)
					}
				})
		} else {
			button
		}
	}

	@ViewBuilder
	private func label(for key: ToolbarKey) -> some View {
		if isCompact {
			KeyIcon(systemName: key.key.compactText ? nil : key.key.imageName,
							fallback: key.key.glyph ?? key.key.label)
				.accessibilityLabel(key.key.label)
		} else {
			switch key {
			case .up, .down, .left, .right,
					 .home, .end, .pageUp, .pageDown:
				KeyIcon(systemName: key.key.imageName, fallback: key.key.glyph ?? key.key.label)
					.frame(width: 14, height: 14, alignment: .center)
					.accessibilityLabel(key.key.label)

			default:
				VStack(alignment: .trailing, spacing: 2) {
					HStack(spacing: 0) {
						if let symbol = key.key.imageName,
							 key.key.preferredStyle != .text {
							Image(systemName: symbol)
								.imageScale(.small)
								.opacity(0.5)
								.frame(width: 14, height: 14, alignment: .center)
								.padding(.trailing, 1)
								.accessibilityLabel(key.key.label)
						}
					}
					.frame(height: 14)

					Text((key.key.glyph ?? key.key.label).localizedLowercase)
				}
			}
		}
	}

	@ViewBuilder
	var arrowsView: some View {
		switch arrowsStyle ?? preferences.keyboardArrowsStyle {
		case .butterfly:
			HStack(spacing: isBigDevice ? 5 : 2) {
				button(for: .left)
				VStack(spacing: 2) {
					button(for: .up, halfHeight: true)
					button(for: .down, halfHeight: true)
				}
				button(for: .right)
			}

		case .scissor:
			HStack(spacing: isBigDevice ? 5 : 2) {
				VStack(alignment: .trailing, spacing: 2) {
					Spacer()
					button(for: .left, halfHeight: true)
				}
				VStack(alignment: .trailing, spacing: 2) {
					button(for: .up, halfHeight: true)
					button(for: .down, halfHeight: true)
				}
				VStack(alignment: .trailing, spacing: 2) {
					Spacer()
					button(for: .right, halfHeight: true)
				}
			}

		case .classic:
			HStack(spacing: 5) {
				button(for: .up)
				button(for: .down)
				button(for: .left)
				button(for: .right)
			}

		case .vim:
			HStack(spacing: 5) {
				button(for: .left)
				button(for: .down)
				button(for: .up)
				button(for: .right)
			}

		case .vimInverted:
			HStack(spacing: 5) {
				button(for: .left)
				button(for: .up)
				button(for: .down)
				button(for: .right)
			}
		}
	}
}

struct KeyboardToolbarView: View {
	// iPhone sizes, from iSH's toolbar: 32 pt keys on a 36 pt bar, with 6 pt padding.
	static let compactMaxKeyWidth: CGFloat = 32
	static let compactSpacing: CGFloat = 6
	static let compactPadding: CGFloat = 6
	static let compactRowHeight = KeyboardKeyButtonStyle.compactHeight + compactPadding * 2

	weak var delegate: KeyboardToolbarViewDelegate?

	let toolbars: [Toolbar]

	@ObservedObject private var preferences = Preferences.shared

	/// The widest keys, up to iSH's size, that still fit the whole toolbar on one row.
	private func keyWidth(for toolbar: Toolbar, width: CGFloat) -> CGFloat {
		var keyCount: CGFloat = 0
		var fixedWidth = Self.compactPadding * 2
		var itemCount = 0
		for key in toolbar.keys {
			switch key {
			case .fixedSpace:
				continue

			case .arrows:
				switch preferences.keyboardArrowsStyle {
				case .butterfly, .scissor:
					keyCount += 3
					fixedWidth += 2 * 2
				case .classic, .vim, .vimInverted:
					keyCount += 4
					fixedWidth += 3 * 5
				}

			case .variableSpace:
				break

			default:
				keyCount += 1
			}
			itemCount += 1
		}
		fixedWidth += CGFloat(max(itemCount - 1, 0)) * Self.compactSpacing

		return max(20, min(Self.compactMaxKeyWidth, ((width - fixedWidth) / max(keyCount, 1)).rounded(.down)))
	}

	var body: some View {
		// KeyboardToolbarInputView sets the height; the rows sit at the top of it.
		GeometryReader { geometry in
			VStack(spacing: 0) {
				ForEach(toolbars, id: \.self) { toolbar in
					KeyboardToolbarKeyStack(delegate: delegate,
																	toolbar: toolbar,
																	compactKeyWidth: keyWidth(for: toolbar, width: geometry.size.width))
						.frame(height: KeyboardKeyButtonStyle.compactHeight)
						.padding(Self.compactPadding)
				}
			}
		}
	}
}

struct KeyboardToolbarView_Previews: PreviewProvider {
	@State private static var state = KeyboardToolbarViewState()

	static var previews: some View {
		ForEach(ColorScheme.allCases, id: \.self) { scheme in
			VStack {
				Spacer()
				KeyboardToolbarView(toolbars: [.primary])
					.environmentObject(state)
					.background(BlurEffectView(style: .systemChromeMaterial))
					.preferredColorScheme(scheme)
					.previewLayout(.sizeThatFits)
			}
				.previewDisplayName("\(scheme)")
				.previewLayout(.fixed(width: 375, height: 100))
		}

		VStack() {
			Spacer()
			HStack {
				KeyboardToolbarKeyStack(toolbar: .padPrimaryLeading)
					.environmentObject(state)
				Spacer()
				KeyboardToolbarKeyStack(toolbar: .padPrimaryTrailing)
					.environmentObject(state)
			}
				.previewLayout(.sizeThatFits)
		}
			.previewDisplayName("iPad Toolbar")
			.previewLayout(.fixed(width: 600, height: 100))
	}
}
