//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import SwiftUIX
import NewTermCommon

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

	var initialCommand: String?

	override var isSplitViewResizing: Bool {
		didSet { updateIsSplitViewResizing() }
	}
	override var showsTitleView: Bool {
		didSet { updateShowsTitleView() }
	}
	override var screenSize: ScreenSize? {
		get { terminalController.screenSize }
		set { terminalController.screenSize = newValue }
	}

	private var terminalController = TerminalController()
	private var keyInput = TerminalKeyInput(frame: .zero)
	private var textView: TerminalHostingView!
	private var textViewTapGestureRecognizer: UITapGestureRecognizer!
	private var keyboardToggleGestureRecognizer: UITapGestureRecognizer!
	private let selectionView = TerminalSelectionView(frame: .zero)
	private var contentSizeObservation: NSKeyValueObservation?
	private var contentOffsetObservation: NSKeyValueObservation?
	private weak var observedScrollView: UIScrollView?

	private var state = TerminalState()

	private var hudState = HUDViewState()
	private var hudView: UIHostingView<AnyView>!

	private var hasAppeared = false
	private var hasStarted = false
	private var failureError: Error?

	private var lastAutomaticScrollOffset = CGPoint.zero
	private var invertScrollToTop = false

	private var isPickingFileForUpload = false

	override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

		terminalController.delegate = self

		do {
			try terminalController.startSubProcess()
			hasStarted = true
		} catch {
			failureError = error
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		super.loadView()

		title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		preferencesUpdated()
		textView = TerminalHostingView(state: state)

		textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
		textViewTapGestureRecognizer.delegate = self
		textView.addGestureRecognizer(textViewTapGestureRecognizer)

		// A tap shows the keyboard and selecting hides it (see handleTextViewTap(_:)); a two-finger
		// tap, like the toolbar's kb key, shows or hides it.
		keyboardToggleGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleKeyboardToggleTap(_:)))
		keyboardToggleGestureRecognizer.numberOfTouchesRequired = 2
		textView.addGestureRecognizer(keyboardToggleGestureRecognizer)

		keyInput.frame = view.bounds
		keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		keyInput.textView = textView
		keyInput.terminalInputDelegate = terminalController
		keyInput.selectAllHandler = { [weak self] in self?.selectAllText() }
		keyInput.confirmPasteHandler = { [weak self] lineCount, paste in
			self?.confirmPaste(lineCount: lineCount, paste: paste)
		}
		view.addSubview(keyInput)

		selectionView.terminalController = terminalController
		// While selecting, the selection view shows the same toolbar with the keyboard hidden, so the
		// toolbar doesn't move when focus goes back and forth.
		selectionView.sharedInputView = keyInput.emptyInputView
		selectionView.sharedInputAccessoryView = keyInput.inputAccessoryView
		selectionView.selectionActiveDidChange = { [weak self] isActive in
			self?.selectionActiveDidChange(isActive)
		}
		selectionView.pasteHandler = { [weak self] in
			guard let self = self else { return }
			// Pasting is going back to typing, so the keyboard comes back, as it does for a tap.
			self.keyInput.showSoftwareKeyboard()
			self.keyInput.paste(nil)
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		hudView = UIHostingView(rootView: AnyView(
			HUDView()
				.environmentObject(self.hudState)
		))
		hudView.translatesAutoresizingMaskIntoConstraints = false
		// The HUD is a fixed 54 pt square. Sized to fit its content, it could measure 54 and 54.33 pt
		// on alternate layout passes when the keyboard's height had float noise, which never settled
		// and hung launch.
		hudView.shouldResizeToFitContent = false
		view.addSubview(hudView)

		NSLayoutConstraint.activate([
			hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
			hudView.widthAnchor.constraint(equalToConstant: 54),
			hudView.heightAnchor.constraint(equalToConstant: 54)
		])

		addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
															 image: UIImage(systemName: "text.badge.xmark"),
															 action: #selector(self.clearTerminal),
															 input: "k",
															 modifierFlags: .command))

		addKeyCommand(UIKeyCommand(title: .localize("Select All"),
															 image: UIImage(systemName: "selection.pin.in.out"),
															 action: #selector(self.selectAllText),
															 input: "a",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
															 image: UIImage(systemName: "key.fill"),
															 action: #selector(self.activatePasswordManager),
															 input: "f",
															 modifierFlags: [ .command, .alternate ]))
		#endif

		if UIApplication.shared.supportsMultipleScenes {
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		keyInput.becomeFirstResponder()
		terminalController.terminalWillAppear()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		hasAppeared = true

		if let error = failureError {
			didReceiveError(error: error)
		} else {
			if let initialCommand = initialCommand?.data(using: .utf8) {
				terminalController.write(initialCommand + EscapeSequences.return)
			}
		}

		initialCommand = nil
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		keyInput.resignFirstResponder()
		terminalController.terminalWillDisappear()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		hasAppeared = false
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()
		updateScreenSize()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateSelectionView()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateScreenSize()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateScreenSize()
	}

	override func removeFromParent() {
		if hasStarted {
			do {
				try terminalController.stopSubProcess()
			} catch {
				Logger().error("Failed to stop subprocess: \(String(describing: error))")
			}
		}

		super.removeFromParent()
	}

	// MARK: - Screen

	func updateScreenSize() {
		if isSplitViewResizing {
			return
		}

		// Determine the screen size based on the font size
		var layoutSize = textView.safeAreaLayoutGuide.layoutFrame.size
		layoutSize.width -= TerminalView.horizontalSpacing * 2
		layoutSize.height -= TerminalView.verticalSpacing * 2

		if layoutSize.width < 0 || layoutSize.height < 0 {
			// Not laid out yet. We’ll be called again when we are.
			return
		}

		let glyphSize = terminalController.fontMetrics.boundingBox
		if glyphSize.width == 0 || glyphSize.height == 0 {
			fatalError("Failed to get glyph size")
		}

		let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
														 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
														 cellSize: glyphSize)
		if screenSize != newSize {
			screenSize = newSize
			delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
		}
	}

	@objc func clearTerminal() {
		terminalController.clearTerminal()
		// Everything left fits on screen, so new output should follow.
		state.isFollowingOutput = true
	}

	private func updateIsSplitViewResizing() {
		state.isSplitViewResizing = isSplitViewResizing

		if !isSplitViewResizing {
			updateScreenSize()
		}
	}

	private func updateShowsTitleView() {
		updateScreenSize()
	}

	// MARK: - Gestures

	/// About as long as a double tap can take, which is how long a tap waits before showing the
	/// keyboard in case it's the start of one.
	private static let doubleTapInterval: TimeInterval = 0.35

	/// The keyboard follows one rule: a tap is for typing, so it shows the keyboard; selecting (long
	/// press, double or triple tap) hides it, and it stays hidden until the next tap.
	@objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
		guard gestureRecognizer.state == .ended else {
			return
		}
		let location = gestureRecognizer.location(in: selectionView)
		// A tap on the selection shows its edit menu.
		if selectionView.hasSelection && selectionView.selectionContains(location) {
			selectionView.showEditMenu(at: location)
			return
		}
		// Any other tap ends the selection and goes back to typing. The keyboard comes up a moment
		// later, unless the tap turned into a double tap that selected something.
		selectionView.clearSelection()
		delegate?.terminalDidBecomeActive(viewController: self)
		let selectionChangeCount = selectionView.selectionChangeCount
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapInterval) { [weak self] in
			guard let self = self,
						self.selectionView.selectionChangeCount == selectionChangeCount else {
				return
			}
			self.keyInput.showSoftwareKeyboard()
		}
	}

	@objc private func handleKeyboardToggleTap(_ gestureRecognizer: UITapGestureRecognizer) {
		guard gestureRecognizer.state == .ended else {
			return
		}
		selectionView.clearSelection()
		keyInput.toggleSoftwareKeyboard()
		delegate?.terminalDidBecomeActive(viewController: self)
	}

	// MARK: - Text selection

	/// Keeps the selection view inside the terminal's scroll view, covering all of its content, so
	/// selections scroll with the text. SwiftUI owns that scroll view, so look it up each time.
	private func updateSelectionView() {
		guard let scrollView = textView.firstSubview(ofType: UIScrollView.self) else {
			return
		}
		if selectionView.superview !== scrollView {
			// Scrolling the terminal shouldn't dismiss the keyboard; kb and two-finger tap do that.
			scrollView.keyboardDismissMode = .none
			scrollView.addSubview(selectionView)
			contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
				DispatchQueue.main.async { self?.updateSelectionView() }
			}
		} else if scrollView.subviews.last !== selectionView {
			scrollView.bringSubviewToFront(selectionView)
		}
		let contentSize = scrollView.contentSize
		selectionView.frame = CGRect(x: 0, y: 0,
																 width: max(contentSize.width, scrollView.bounds.width),
																 height: max(contentSize.height, scrollView.bounds.height))
		let grid = terminalController.textGridSize
		selectionView.update(rowCount: grid.rows,
												 cols: grid.cols,
												 cellSize: terminalController.fontMetrics.boundingBox,
												 origin: CGPoint(x: TerminalView.horizontalSpacing, y: TerminalView.verticalSpacing))
	}

	@objc private func selectAllText() {
		updateSelectionView()
		selectionView.selectAll(nil)
	}

	// MARK: - Following output

	/// Watches the terminal's scroll view, which SwiftUI makes, once it's there.
	private func observeScrolling() {
		guard let scrollView = textView.firstSubview(ofType: UIScrollView.self),
					scrollView !== observedScrollView else {
			return
		}
		observedScrollView = scrollView
		contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
			self?.contentOffsetDidChange(scrollView)
		}
	}

	/// New output scrolls the terminal to the bottom only while it's there (hbang/NewTerm#80). Only
	/// the user's own scrolling decides that: layout, such as the keyboard showing, moves it too.
	private func contentOffsetDidChange(_ scrollView: UIScrollView) {
		guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else {
			return
		}
		// Within a row of the bottom still counts, so a bounce or part of a row doesn't stop it.
		let rowHeight = terminalController.fontMetrics.boundingBox.height
		state.isFollowingOutput = scrollView.contentOffset.y >= bottomContentOffset(of: scrollView) - rowHeight
	}

	private func bottomContentOffset(of scrollView: UIScrollView) -> CGFloat {
		max(scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height,
				-scrollView.adjustedContentInset.top)
	}

	/// Typing or pasting goes back to the bottom, as in other terminals. This checks where the view
	/// is, not just the flag, as moves the user didn't make (a selection keeping its text in view,
	/// say) don't update it.
	private func followOutput() {
		state.isFollowingOutput = true
		if let scrollView = textView.firstSubview(ofType: UIScrollView.self),
			 scrollView.contentOffset.y < bottomContentOffset(of: scrollView) - 1 {
			scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottomContentOffset(of: scrollView)), animated: false)
		}
	}

	/// Whether the view is at the bottom now, for after moves the user didn't make.
	private func updateIsFollowingOutput() {
		guard let scrollView = textView.firstSubview(ofType: UIScrollView.self) else {
			return
		}
		let rowHeight = terminalController.fontMetrics.boundingBox.height
		state.isFollowingOutput = scrollView.contentOffset.y >= bottomContentOffset(of: scrollView) - rowHeight
	}

	// MARK: - Paste

	private func confirmPaste(lineCount: Int, paste: @escaping () -> Void) {
		let alertController = UIAlertController(title: String(format: .localize("Paste %li Lines?"), lineCount),
																						message: .localize("Each line will run as soon as it’s pasted, as if you typed it and pressed return."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel) { [weak self] _ in
			self?.keyInput.becomeFirstResponder()
		})
		alertController.addAction(UIAlertAction(title: .localize("Paste"), style: .default) { [weak self] _ in
			paste()
			self?.keyInput.becomeFirstResponder()
		})
		present(alertController, animated: true, completion: nil)
	}

	private func selectionActiveDidChange(_ isActive: Bool) {
		state.isSelecting = isActive
		if !isActive {
			// While selecting, the view moved with the text, so it may no longer be at the bottom.
			updateIsFollowingOutput()
		}
		// Selecting takes focus, which hides the keyboard. When the selection ends, typing focus comes
		// back with the keyboard still hidden, so it only comes back with a tap.
		if !isActive && hasAppeared && !keyInput.isFirstResponder && selectionView.isFirstResponder {
			keyInput.hideSoftwareKeyboard()
		}
	}

	// MARK: - Lifecycle

	@objc private func sceneDidEnterBackground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowDidEnterBackground()
		}
	}

	@objc private func sceneWillEnterForeground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowWillEnterForeground()
		}
	}

	@objc private func preferencesUpdated() {
		state.fontMetrics = terminalController.fontMetrics
		state.colorMap = terminalController.colorMap

		// A new font size fits a different number of rows and columns.
		if textView != nil {
			updateScreenSize()
		}
	}

}

extension TerminalSessionViewController: TerminalControllerDelegate {

	func refresh(lines: [AnyView], droppedRows: Int) {
		if droppedRows > 0 {
			// Every row moved up. Keep the selection on its text, and unless following the output,
			// keep the same text in view.
			selectionView.moveRows(by: -droppedRows)
			if !state.isFollowingOutput || state.isSelecting,
				 let scrollView = textView.firstSubview(ofType: UIScrollView.self),
				 !scrollView.isTracking {
				let rowHeight = terminalController.fontMetrics.boundingBox.height
				scrollView.contentOffset.y = max(scrollView.contentOffset.y - CGFloat(droppedRows) * rowHeight,
																				 -scrollView.adjustedContentInset.top)
			}
		}
		state.lines = lines
		observeScrolling()
		updateSelectionView()
	}

	func didReceiveKeyboardInput() {
		followOutput()
	}

	func activateBell() {
		if Preferences.shared.bellHUD {
			hudState.isVisible = true
		}

		HapticController.playBell()
	}

	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
		let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
		delegate?.terminal(viewController: self,
											 titleDidChange: newTitle,
											 isDirty: isDirty,
											 hasBell: hasBell)
	}

	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
		#if targetEnvironment(macCatalyst)
		if let windowScene = view.window?.windowScene {
			windowScene.titlebar?.representedURL = url
		}
		#endif
	}

	func saveFile(url: URL) {
		let viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	func fileUploadRequested() {
		isPickingFileForUpload = true

		let viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	@objc func activatePasswordManager() {
		keyInput.activatePasswordManager()
	}

	@objc func close() {
		if let splitViewController = parent as? TerminalSplitViewController {
			splitViewController.remove(viewController: self)
		}
	}

	func didReceiveError(error: Error) {
		if !hasAppeared {
			failureError = error
			return
		}
		failureError = nil

		let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
																						message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

}

extension TerminalSessionViewController: UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// This allows the tap-to-activate-keyboard gesture to work without conflicting with UIKit’s
		// internal text view/scroll view gestures… as much as we can avoid conflicting, at least.
		// The text selection's own gestures (long press, handles, loupe) don't all fail on a plain
		// tap, so waiting on them would stop a tap from ever bringing the keyboard back. Telling a tap
		// from a double tap is handleTextViewTap(_:)'s job.
		if let view = otherGestureRecognizer.view, view.isDescendant(of: selectionView) {
			return false
		}
		return gestureRecognizer == textViewTapGestureRecognizer
			&& (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
	}
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard isPickingFileForUpload,
					let url = urls.first else {
			return
		}
		terminalController.uploadFile(url: url)
		isPickingFileForUpload = false
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		if isPickingFileForUpload {
			isPickingFileForUpload = false
			terminalController.cancelUploadRequest()
		} else {
			// The system will clean up the temp directory for us eventually anyway, but still delete the
			// downloads temp directory now so the file doesn’t linger around till then.
			terminalController.deleteDownloadCache()
		}
	}

}

fileprivate extension UIView {
	/// The first view of a type in this view's subtree, breadth first.
	func firstSubview<T: UIView>(ofType type: T.Type) -> T? {
		var queue = subviews
		while !queue.isEmpty {
			let view = queue.removeFirst()
			if let match = view as? T {
				return match
			}
			queue += view.subviews
		}
		return nil
	}
}
