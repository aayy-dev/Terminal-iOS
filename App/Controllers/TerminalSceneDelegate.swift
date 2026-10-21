//
//  TerminalSceneDelegate.swift
//  NewTerm
//
//  Created by Adam Demasi on 16/6/19.
//  Copyright © 2019 HASHBANG Productions. All rights reserved.
//

import UIKit
import NewTermCommon

extension NSUserActivity {
	static let terminalScene = NSUserActivity(activityType: TerminalSceneDelegate.activityType)
}

class TerminalSceneDelegate: UIResponder, UIWindowSceneDelegate, IdentifiableSceneDelegate {

	static let activityType = "ws.hbang.Terminal.TerminalSceneActivity"

	var window: UIWindow?

	private var rootViewController: RootViewController! {
		(window?.rootViewController as? UINavigationController)?.viewControllers.first as? RootViewController
	}

	override init() {
		super.init()

		NotificationCenter.default.addObserver(self, selector: #selector(preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
	}

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		guard let scene = scene as? UIWindowScene else {
			return
		}

		// A link that launched the app, or that this window was opened for, runs in the first tab.
		let rootViewController = RootViewController()
		if let url = Self.sshURL(in: connectionOptions) {
			rootViewController.initialCommand = Self.sshCommand(for: url)
		}

		window = UIWindow(windowScene: scene)
		window!.tintColor = .tint
		window!.rootViewController = UINavigationController(rootViewController: rootViewController)
		window!.makeKeyAndVisible()

		scene.title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		#if targetEnvironment(macCatalyst)
		scene.titlebar?.separatorStyle = .none
		scene.titlebar?.toolbarStyle = .unifiedCompact
		#endif

		preferencesUpdated()
	}

	func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
		for context in URLContexts {
			let url = context.url
			switch url.scheme {
			case "ssh":
				createWindow(asTab: true, openingURL: url)

			default: break
			}
		}
	}

	// MARK: - Window management

	func createWindow(asTab: Bool, openingURL url: URL? = nil) {
		if UIApplication.shared.supportsMultipleScenes {
			let options = UIScene.ActivationRequestOptions()
			#if targetEnvironment(macCatalyst)
			if asTab {
				options.requestingScene = window!.windowScene
			}
			options.collectionJoinBehavior = asTab ? .preferred : .disallowed
			#else
			options.requestingScene = window!.windowScene
			#endif

			// The new window makes the ssh command from the link itself (see sshURL(in:)).
			let activity = NSUserActivity(activityType: Self.activityType)
			activity.userInfo = [:]
			if let url = url {
				activity.userInfo!["sshURL"] = url.absoluteString
			}

			UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: options, errorHandler: nil)
		} else {
			if let url = url {
				rootViewController.initialCommand = Self.sshCommand(for: url)
			}
			rootViewController.addTerminal()
		}
	}

	@objc func removeWindow() {
		UIApplication.shared.requestSceneSessionDestruction(window!.windowScene!.session, options: nil, errorHandler: nil)
	}

	// MARK: - SSH links

	/// What an ssh:// link’s user and host may contain. They arrive percent-decoded and get typed
	/// into the shell, so only plain names are accepted, and they’re quoted as well.
	private static let sshNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

	/// The link a new scene was opened for: one that launched the app, which UIKit gives to
	/// scene(_:willConnectTo:options:) and not to scene(_:openURLContexts:), or one that
	/// createWindow(asTab:openingURL:) opened a window for.
	private static func sshURL(in connectionOptions: UIScene.ConnectionOptions) -> URL? {
		if let context = connectionOptions.urlContexts.first(where: { context in context.url.scheme == "ssh" }) {
			return context.url
		}
		if let activity = connectionOptions.userActivities.first(where: { activity in activity.activityType == Self.activityType }),
			 let urlString = activity.userInfo?["sshURL"] as? String {
			return URL(string: urlString)
		}
		return nil
	}

	/// The command to type for an ssh:// link, or nil if it has no host, or a user or host that isn’t
	/// a plain name.
	private static func sshCommand(for url: URL) -> String? {
		guard url.scheme == "ssh",
					let host = url.host,
					isPlainSSHName(host, allowingColons: true) else {
			return nil
		}

		var command = "ssh"
		if let user = url.user, !user.isEmpty {
			guard isPlainSSHName(user, allowingColons: false) else {
				return nil
			}
			command += " -l \(shellQuoted(user))"
		}
		if let port = url.port, port != 22 {
			guard (1...65535).contains(port) else {
				return nil
			}
			command += " -p \(port)"
		}
		return "\(command) \(shellQuoted(host))"
	}

	private static func isPlainSSHName(_ name: String, allowingColons: Bool) -> Bool {
		// A leading - would be read as an option. Colons are for IPv6 addresses.
		let characters = allowingColons ? sshNameCharacters.union(CharacterSet(charactersIn: ":")) : sshNameCharacters
		return !name.isEmpty
			&& !name.hasPrefix("-")
			&& name.unicodeScalars.allSatisfy { character in characters.contains(character) }
	}

	private static func shellQuoted(_ string: String) -> String {
		"'\(string.replacingOccurrences(of: "'", with: #"'\''"#))'"
	}

	// MARK: - Preferences

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		window?.overrideUserInterfaceStyle = preferences.userInterfaceStyle
	}

	// MARK: - Updates

	func handleUpdateAvailable(_ response: UpdateCheckResponse) {
		guard let viewController = window?.rootViewController else {
			return
		}

		let infoPlist = Bundle.main.infoDictionary!
		let appVersion = infoPlist["CFBundleShortVersionString"] as! String

		let alertController = UIAlertController(title: "Update Available",
																						message: "Version \(response.versionString) is available to install. You’re currently using version \(appVersion).",
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: nil))
		alertController.addAction(UIAlertAction(title: "Download", style: .default, handler: { _ in
			UIApplication.shared.open(URL(string: response.url)!, options: [:], completionHandler: nil)
		}))
		viewController.present(alertController, animated: true, completion: nil)
	}

}
