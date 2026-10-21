//
//  TerminalKeyInput.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import NewTermCommon
import SwiftUIX

extension ToolbarKey {
	var keySequence: [UTF8Char] {
		switch self {
		case .escape:   return EscapeSequences.meta
		case .tab:      return EscapeSequences.tab
		case .up:       return EscapeSequences.up
		case .down:     return EscapeSequences.down
		case .left:     return EscapeSequences.left
		case .right:    return EscapeSequences.right
		case .home:     return EscapeSequences.home
		case .end:      return EscapeSequences.end
		case .pageUp:   return EscapeSequences.pageUp
		case .pageDown: return EscapeSequences.pageDown
		case .delete:   return EscapeSequences.delete
		case .fnKey(let index): return EscapeSequences.fn[index - 1]
		case .fixedSpace, .variableSpace, .arrows,
				 .control, .fn, .selectAll, .paste, .keyboard:
			return []
		}
	}

	var appKeySequence: [UTF8Char]? {
		switch self {
		case .up:       return EscapeSequences.upApp
		case .down:     return EscapeSequences.downApp
		case .left:     return EscapeSequences.leftApp
		case .right:    return EscapeSequences.rightApp
		case .home:     return EscapeSequences.homeApp
		case .end:      return EscapeSequences.endApp
		default:        return nil
		}
	}

	func keySequence(applicationCursor: Bool = false) -> [UTF8Char] {
		(applicationCursor ? appKeySequence : nil) ?? keySequence
	}
}

class TerminalKeyInput: TextInputBase {

	weak var terminalInputDelegate: TerminalInputProtocol?
	/// Called by the toolbar's Select All key; the text selection lives in the session.
	var selectAllHandler: (() -> Void)?
	/// Asks before pasting several lines into a program that can't hold them for review, since each
	/// line would run as it arrives. Calls `paste` if the user goes ahead.
	var confirmPasteHandler: ((_ lineCount: Int, _ paste: @escaping () -> Void) -> Void)?

	/// While true the on-screen keyboard is swapped for an empty view, so only the toolbar shows
	/// and more of the terminal is visible. The toolbar's keyboard key and a tap bring it back.
	private(set) var isSoftwareKeyboardHidden = false {
		didSet {
			if isSoftwareKeyboardHidden != oldValue {
				reloadInputViews()
			}
		}
	}
	/// Stands in for the on-screen keyboard while it's hidden. The selection view uses it too.
	let emptyInputView = UIView(frame: .zero)

	override var inputView: UIView? { isSoftwareKeyboardHidden ? emptyInputView : nil }

	/// Whether the on-screen keyboard (not just the toolbar) is showing right now, from the
	/// keyboard's own frame, so the keyboard key acts on what's actually on screen.
	private(set) var isSoftwareKeyboardOnScreen = false

	func showSoftwareKeyboard() {
		isSoftwareKeyboardHidden = false
		if !isFirstResponder {
			_ = becomeFirstResponder()
		}
	}

	/// Hides the keyboard but keeps the toolbar (and typing focus).
	func hideSoftwareKeyboard() {
		isSoftwareKeyboardHidden = true
		if !isFirstResponder {
			_ = becomeFirstResponder()
		}
	}

	/// The keyboard key and two-finger tap: hide the keyboard if it's showing, show it otherwise.
	func toggleSoftwareKeyboard() {
		if isSoftwareKeyboardOnScreen {
			hideSoftwareKeyboard()
		} else {
			showSoftwareKeyboard()
		}
	}

	@objc private func keyboardFrameWillChange(_ notification: Notification) {
		guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
			return
		}
		let screenHeight = window?.screen.bounds.height ?? UIScreen.main.bounds.height
		let onScreenHeight = max(0, screenHeight - frame.minY)
		let toolbarHeight = toolbar?.frame.height ?? 0
		isSoftwareKeyboardOnScreen = onScreenHeight - toolbarHeight > 40
	}
	weak var textView: UIView! {
		didSet {
			textView.frame = bounds
			textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			insertSubview(textView, at: 0)
		}
	}

	private var toolbar: KeyboardToolbarInputView?
	private var passwordInputView: TerminalPasswordInputView?

	private var previousFloatingCursorPoint: CGPoint? = nil
	private var repeatTimer: Timer?

	private var state = KeyboardToolbarViewState()
	/// The hardware key that repeats while it's held: the last one pressed, as on a Mac.
	private var repeatingHardwareKey: UIKey?
	private var pressedToolbarKeys = Set<ToolbarKey>()

	override init(frame: CGRect) {
		super.init(frame: frame)

		autocapitalizationType = .none
		autocorrectionType = .no
		spellCheckingType = .no
		smartQuotesType = .no
		smartDashesType = .no
		smartInsertDeleteType = .no

		if UIDevice.current.userInterfaceIdiom == .pad {
			let leadingView = KeyboardToolbarPadItemView(delegate: self,
																									 toolbar: .padPrimaryLeading,
																									 state: state)
			let trailingView = KeyboardToolbarPadItemView(delegate: self,
																										toolbar: .padPrimaryTrailing,
																										state: state)

			inputAssistantItem.allowsHidingShortcuts = false

			if #available(iOS 16, *) {
				inputAssistantItem.leadingBarButtonGroups += [
					.fixedGroup(items: [UIBarButtonItem(customView: leadingView)])
				]
				inputAssistantItem.trailingBarButtonGroups += [
					.fixedGroup(items: [UIBarButtonItem(customView: trailingView)])
				]
			} else {
				inputAssistantItem.leadingBarButtonGroups += [
					UIBarButtonItemGroup(barButtonItems: [UIBarButtonItem(customView: leadingView)], representativeItem: nil)
				]
				inputAssistantItem.trailingBarButtonGroups += [
					UIBarButtonItemGroup(barButtonItems: [UIBarButtonItem(customView: trailingView)], representativeItem: nil)
				]
			}
		} else {
			// The iPad's keys are in the shortcuts bar above; the iPhone gets this toolbar.
			toolbar = KeyboardToolbarInputView(delegate: self,
																				 toolbars: [.primary],
																				 state: state)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
	}

	required init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var inputAccessoryView: UIView? { toolbar }

	// MARK: - Password manager

	func activatePasswordManager() {
		// Trigger the iOS password manager button, or cancel the operation.
		if let passwordInputView = passwordInputView {
			// Cancelled: drop the password field and take the keyboard back. Leaving it set would send
			// every later becomeFirstResponder() to a field that's no longer on screen, so the
			// keyboard could never come back.
			passwordInputView.removeFromSuperview()
			self.passwordInputView = nil
			_ = becomeFirstResponder()
		} else {
			passwordInputView = TerminalPasswordInputView()
			passwordInputView!.passwordDelegate = self
			addSubview(passwordInputView!)
			passwordInputView!.becomeFirstResponder()
		}
	}

	// MARK: - UITextInput

	override var hasText: Bool { true }

	override func insertText(_ text: String) {
		// Used by the software keyboard only. See pressesBegan(_:with:) below for hardware keyboard.
		if state.toggledKeys.contains(.fn) {
			state.toggledKeys.remove(.fn)
			if let key = Self.functionKey(for: text) {
				// The F key uses up ctrl too, rather than leaving it on for the next key.
				state.toggledKeys.remove(.control)
				terminalInputDelegate!.receiveKeyboardInput(data: key.keySequence)
				return
			}
		}

		let isCtrlDown = state.toggledKeys.contains(.control)
		let data = text.utf8.map { character -> UTF8Char in
			// Convert newline to carriage return
			if character == 0x0A {
				return EscapeSequences.return.first!
			}
			if isCtrlDown {
				return character.controlCharacter
			}
			return character
		}

		terminalInputDelegate!.receiveKeyboardInput(data: data)

		if isCtrlDown {
			state.toggledKeys.remove(.control)
		}

//		if !moreToolbar.isHidden {
//			setMoreRowVisible(false, animated: true)
//		}
	}

	override func deleteBackward() {
		// fn and delete deletes forward, like on a Mac. It applies to one press, so holding delete
		// goes back to deleting backward.
		if state.toggledKeys.contains(.fn) {
			state.toggledKeys.subtract([.fn, .control])
			terminalInputDelegate!.receiveKeyboardInput(data: EscapeSequences.delete)
			return
		}
		terminalInputDelegate!.receiveKeyboardInput(data: EscapeSequences.backspace)
	}

	private static let functionKeyCharacters = Array("1234567890-=")

	/// fn and the number row type F1 to F12, like on a Mac: 1 to 0 for F1 to F10, then - and =.
	private static func functionKey(for text: String) -> ToolbarKey? {
		guard text.count == 1,
					let index = functionKeyCharacters.firstIndex(of: text.first!) else {
			return nil
		}
		return .fnKey(index: index + 1)
	}

	func beginFloatingCursor(at point: CGPoint) {
		previousFloatingCursorPoint = point
	}

	func updateFloatingCursor(at point: CGPoint) {
		guard let oldPoint = previousFloatingCursorPoint else {
			return
		}

		let threshold: CGFloat
		switch Preferences.shared.keyboardTrackpadSensitivity {
		case .off:    return
		case .low:    threshold = 8
		case .medium: threshold = 5
		case .high:   threshold = 2
		}

		let difference = point.x - oldPoint.x
		if abs(difference) < threshold {
			return
		}
		keyboardToolbarDidPressKey(difference < 0 ? .left : .right)
		previousFloatingCursorPoint = point
	}

	func endFloatingCursor() {
		previousFloatingCursorPoint = nil
	}

	// MARK: - UIResponder

	@discardableResult
	override func becomeFirstResponder() -> Bool {
		if let passwordInputView = passwordInputView {
			return passwordInputView.becomeFirstResponder()
		} else {
			_ = super.becomeFirstResponder()
			return true
		}
	}

	@discardableResult
	override func resignFirstResponder() -> Bool {
		super.resignFirstResponder()
	}

	override var canBecomeFirstResponder: Bool { true }

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		switch action {
		case #selector(self.paste(_:)):
			// Only paste if the pasteboard contains a plaintext type
			return UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs

		case #selector(self.cut(_:)):
			// Ensure cut is never allowed
			return false

		default:
			return super.canPerformAction(action, withSender: sender)
		}
	}

	override func copy(_ sender: Any?) {
//		textView?.copy(sender)
	}

	override func paste(_ sender: Any?) {
		// Reading the pasteboard from code can make iOS ask for permission, so read it only once.
		let pasteboard = UIPasteboard.general
		let text = pasteboard.hasStrings ? pasteboard.string : (pasteboard.hasURLs ? pasteboard.url?.absoluteString : nil)
		if let text = text {
			paste(text: text)
		}
	}

	/// Pastes so that nothing runs until you press return. Shells turn on bracketed paste at their
	/// prompt, which puts the whole paste on the command line; anywhere else, each line of a paste
	/// would run as it arrives, so several lines are confirmed first.
	func paste(text: String) {
		guard let terminalInputDelegate = terminalInputDelegate else {
			return
		}

		let data = Self.pasteData(for: text)
		if data.isEmpty {
			return
		}

		let lineCount = data.filter { $0 == EscapeSequences.return.first! }.count + 1
		if !terminalInputDelegate.bracketedPasteMode && lineCount > 1,
			 let confirmPasteHandler = confirmPasteHandler {
			confirmPasteHandler(lineCount) { [weak self] in
				// Sent as things are now: the program may have turned on bracketed paste meanwhile.
				self?.send(pasteData: data)
			}
		} else {
			send(pasteData: data)
		}
	}

	private func send(pasteData data: [UTF8Char]) {
		guard let terminalInputDelegate = terminalInputDelegate else {
			return
		}
		if terminalInputDelegate.bracketedPasteMode {
			terminalInputDelegate.receiveKeyboardInput(data: EscapeSequences.bracketedPasteStart + data + EscapeSequences.bracketedPasteEnd)
		} else {
			terminalInputDelegate.receiveKeyboardInput(data: data)
		}
	}

	/// Text to paste, as it would be typed: line breaks (including Unicode's) become returns,
	/// except one at the very end, so pasting a copied line doesn't run it. Control characters
	/// other than tab are dropped, since they could act on the terminal, or end a bracketed paste
	/// early and run the rest.
	static func pasteData(for text: String) -> [UTF8Char] {
		var result = String.UnicodeScalarView()
		var previous: Unicode.Scalar?
		for scalar in text.unicodeScalars {
			defer { previous = scalar }
			switch scalar.value {
			case 0x09:
				result.append(scalar)
			case 0x0A where previous == "\r":
				// The second half of a CRLF.
				continue
			case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
				result.append("\r")
			case 0x00...0x1F, 0x7F...0x9F:
				continue
			default:
				result.append(scalar)
			}
		}
		if result.last == "\r" {
			result.removeLast()
		}
		return String(result).utf8Array
	}

	// MARK: - Hardware keyboard

	@discardableResult
	private func handleKey(_ key: UIKey) -> Bool {
		// We don‘t want to handle cmd, let UIKit handle that.
		if key.modifierFlags.contains(.command) {
			return false
		}

		// The toolbar's fn works on hardware keyboards too, for ones without F keys or forward delete.
		if state.toggledKeys.contains(.fn) && !Self.modifierKeyCodes.contains(key.keyCode) {
			state.toggledKeys.remove(.fn)
			if let keyData = functionKeySequence(for: key) {
				terminalInputDelegate?.receiveKeyboardInput(data: keyData)
				return true
			}
		}

		var keyData: [UTF8Char]
		switch key.keyCode {
		case .keyboardReturnOrEnter: keyData = EscapeSequences.return
		case .keyboardEscape:        keyData = EscapeSequences.meta
		case .keyboardDeleteOrBackspace: keyData = EscapeSequences.backspace
		case .keyboardDeleteForward: keyData = EscapeSequences.delete

		case .keyboardHome:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.homeApp : EscapeSequences.home

		case .keyboardEnd:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.endApp : EscapeSequences.end

		case .keyboardUpArrow:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up

		case .keyboardDownArrow:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down

		case .keyboardLeftArrow:
			if key.modifierFlags.contains(.alternate) {
				keyData = EscapeSequences.leftMeta
			} else if terminalInputDelegate!.applicationCursor {
				keyData = EscapeSequences.leftApp
			} else {
				keyData = EscapeSequences.left
			}

		case .keyboardRightArrow:
			if key.modifierFlags.contains(.alternate) {
				keyData = EscapeSequences.rightMeta
			} else if terminalInputDelegate!.applicationCursor {
				keyData = EscapeSequences.rightApp
			} else {
				keyData = EscapeSequences.right
			}

		case .keyboardPageUp:     keyData = EscapeSequences.pageUp
		case .keyboardPageDown:   keyData = EscapeSequences.pageDown

		case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6, .keyboardF7,
				.keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
			keyData = EscapeSequences.fn[key.keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue]

		default: keyData = key.characters.utf8Array
		}

		// If we didn’t get anything to type, nothing else to do here.
		if keyData.isEmpty {
			return false
		}

		// Translate ctrl key sequences to the approriate escape.
		if key.modifierFlags.contains(.control) {
			keyData = keyData.map(\.controlCharacter)
		}

		// Prepend esc before each byte if meta key is down.
		if key.modifierFlags.contains(.alternate) {
			keyData = keyData.reduce([], { result, character in result + EscapeSequences.meta + [character] })
		}

		terminalInputDelegate?.receiveKeyboardInput(data: keyData)
		return true
	}

	private static let modifierKeyCodes: Set<UIKeyboardHIDUsage> = [
		.keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
		.keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock
	]

	/// What a hardware key types while fn is on, if fn changes it: the same as with the toolbar
	/// and the on-screen keyboard.
	private func functionKeySequence(for key: UIKey) -> [UTF8Char]? {
		let applicationCursor = terminalInputDelegate?.applicationCursor ?? false
		switch key.keyCode {
		case .keyboardDeleteOrBackspace: return EscapeSequences.delete
		case .keyboardLeftArrow:  return ToolbarKey.home.keySequence(applicationCursor: applicationCursor)
		case .keyboardRightArrow: return ToolbarKey.end.keySequence(applicationCursor: applicationCursor)
		case .keyboardUpArrow:    return ToolbarKey.pageUp.keySequence(applicationCursor: applicationCursor)
		case .keyboardDownArrow:  return ToolbarKey.pageDown.keySequence(applicationCursor: applicationCursor)
		default:                  return Self.functionKey(for: key.charactersIgnoringModifiers)?.keySequence
		}
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		var isHandled = false
		for press in presses {
			if let key = press.key,
				 handleKey(key) {
				isHandled = true
				repeatingHardwareKey = key
			}
		}

		if isHandled {
			beginKeyRepeat()
		} else {
			super.pressesBegan(presses, with: event)
		}
	}

	private func handlePressesEnded(_ presses: Set<UIPress>) {
		// Letting go of an earlier key, or of a modifier, doesn't stop the key that's repeating.
		guard let repeatingKeyCode = repeatingHardwareKey?.keyCode,
					presses.contains(where: { $0.key?.keyCode == repeatingKeyCode }) else {
			return
		}
		repeatingHardwareKey = nil
		if pressedToolbarKeys.isEmpty {
			endKeyRepeat()
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		handlePressesEnded(presses)
		super.pressesEnded(presses, with: event)
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		handlePressesEnded(presses)
		super.pressesCancelled(presses, with: event)
	}

	private func beginKeyRepeat() {
		// Each new key waits the whole delay. A timer left from an earlier key would repeat this one
		// at that key's deadline, so a short press could type twice.
		endKeyRepeat()

		if KeyboardPreferences.isKeyRepeatEnabled {
			repeatTimer = Timer.scheduledTimer(timeInterval: KeyboardPreferences.keyRepeatDelay,
																				 target: self,
																				 selector: #selector(self.handleKeyRepeat),
																				 userInfo: true,
																				 repeats: false)
		}
	}

	private func endKeyRepeat() {
		repeatTimer?.invalidate()
		repeatTimer = nil
	}

	@objc private func handleKeyRepeat(_ timer: Timer) {
		if let key = repeatingHardwareKey {
			handleKey(key)
		}

		for key in pressedToolbarKeys {
			sendKeySequence(for: key)
		}

		if repeatingHardwareKey == nil && pressedToolbarKeys.isEmpty {
			endKeyRepeat()
			return
		}

		if timer.userInfo as? Bool ?? false {
			repeatTimer = Timer.scheduledTimer(timeInterval: KeyboardPreferences.keyRepeat,
																				 target: self,
																				 selector: #selector(self.handleKeyRepeat),
																				 userInfo: nil,
																				 repeats: true)
		}
	}

}

extension TerminalKeyInput: KeyboardToolbarViewDelegate {
	private func sendKeySequence(for key: ToolbarKey) {
		guard let terminalInputDelegate = terminalInputDelegate else {
			return
		}
		terminalInputDelegate.receiveKeyboardInput(data: key.keySequence(applicationCursor: terminalInputDelegate.applicationCursor))
	}

	func keyboardToolbarDidPressKey(_ key: ToolbarKey) {
		sendKeySequence(for: key)

		switch key {
		case .home, .end, .pageUp, .pageDown:
			// fn and an arrow key: like ctrl, fn applies to one key.
			state.toggledKeys.remove(.fn)

		case .selectAll:
			selectAllHandler?()

		case .paste:
			paste(nil)

		case .keyboard:
			toggleSoftwareKeyboard()

		default: break
		}
	}

	func keyboardToolbarDidBeginPressingKey(_ key: ToolbarKey) {
		switch key {
		case .up, .down, .left, .right,
				 .home, .end, .pageUp, .pageDown,
				 .delete:
			pressedToolbarKeys.insert(key)
			beginKeyRepeat()

		default: break
		}
	}

	func keyboardToolbarDidEndPressingKey(_ key: ToolbarKey) {
		// Turning fn on or off while a key is held swaps an arrow key for Home, End, Page Up or Page
		// Down (or back), so the key that ends may not be the one that began. Let go of both.
		let arrowKeys: [ToolbarKey] = [.up, .down, .left, .right]
		let forms = Set([key, key.functionKey] + arrowKeys.filter { $0.functionKey == key })
		let endedKeys = pressedToolbarKeys.intersection(forms)
		pressedToolbarKeys.subtract(forms)

		if endedKeys.contains(where: { [.home, .end, .pageUp, .pageDown].contains($0) }) {
			// A key held until it repeats isn't also pressed, so let go of fn here too. On the next run
			// loop, so a press that comes with this release still types with fn.
			DispatchQueue.main.async {
				self.state.toggledKeys.remove(.fn)
			}
		}
	}
}

extension TerminalKeyInput: TerminalPasswordInputViewDelegate {

	func passwordInputViewDidComplete(password: String?) {
		if let password = password {
			// User could have typed on the keyboard while it was in password mode, rather than using the
			// password autofill. Send a return if it seems like a password was actually received,
			// otherwise just pretend it was typed like normal.
			if password.count > 2 {
				terminalInputDelegate!.receiveKeyboardInput(data: password.utf8Array + EscapeSequences.return)
			} else {
				insertText(password)
			}
		}
		passwordInputView?.removeFromSuperview()
		passwordInputView = nil
		_ = becomeFirstResponder()
	}

}
