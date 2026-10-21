//
//  TerminalInputProtocol.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 20/6/19.
//

import Foundation

public protocol TerminalInputProtocol: AnyObject {

	func receiveKeyboardInput(data: [UTF8Char])

	var applicationCursor: Bool { get }

	/// Whether the running program asked for pastes to be bracketed, so it can tell pasted text
	/// from typing. Shells do this at their prompt to keep a paste from running until return.
	var bracketedPasteMode: Bool { get }

}
