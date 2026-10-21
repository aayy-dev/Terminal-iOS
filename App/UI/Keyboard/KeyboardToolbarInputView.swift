//
//  KeyboardToolbarInputView.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUIX

class KeyboardToolbarInputView: UIInputView {

	private var hostingView: UIHostingView<AnyView>!
	private var heightConstraint: NSLayoutConstraint!
	private let rowsHeight: CGFloat

	init(delegate: KeyboardToolbarViewDelegate?, toolbars: [Toolbar], state: KeyboardToolbarViewState) {
		rowsHeight = CGFloat(toolbars.count) * KeyboardToolbarView.compactRowHeight
		super.init(frame: .zero, inputViewStyle: .keyboard)

		translatesAutoresizingMaskIntoConstraints = false
		allowsSelfSizing = true

		// The height is set here rather than measured from the SwiftUI content. Measured, it took on
		// the home indicator inset while the toolbar was at the bottom of the screen, and kept it
		// once the keyboard came up, leaving a gap above the keyboard.
		hostingView = UIHostingView(rootView: AnyView(
			KeyboardToolbarView(delegate: delegate, toolbars: toolbars)
				.environmentObject(state)
				.ignoresSafeArea()
		))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		hostingView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		hostingView.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
		addSubview(hostingView)

		heightConstraint = heightAnchor.constraint(equalToConstant: rowsHeight)

		NSLayoutConstraint.activate([
			heightConstraint,
			hostingView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
			hostingView.topAnchor.constraint(equalTo: self.topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func safeAreaInsetsDidChange() {
		super.safeAreaInsetsDidChange()

		// At the bottom of the screen (keyboard hidden, or a hardware keyboard), leave room below the
		// keys for the home indicator. Rounded, so float noise in the keyboard's frame can't keep
		// the toolbar changing height.
		let height = rowsHeight + safeAreaInsets.bottom.rounded()
		if heightConstraint.constant != height {
			heightConstraint.constant = height
		}
	}

}

extension KeyboardToolbarInputView: UIInputViewAudioFeedback {
	var enableInputClicksWhenVisible: Bool {
		// Conforming to <UIInputViewAudioFeedback> allows the buttons to make the click sound
		// when tapped
		true
	}
}
