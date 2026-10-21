//
//  UpdateCheckManager.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 8/4/21.
//

import Foundation

struct UpdateCheckResponse: Codable {
	let versionString: String
	let versionCode: String
	let minimumOSVersion: String
	let url: String
}

class UpdateCheckManager {

	static let updateAvailableNotification = Notification.Name(rawValue: "UpdateCheckManagerUpdateAvailableNotification")

	static func check(updateAvailableCompletion: @escaping (_ repsonse: UpdateCheckResponse) -> ()) {
		// Updates come from the package repo, so there's no update feed to check.
	}

}
