//
//  SubProcess.swift
//  NewTerm
//
//  Created by Adam Demasi on 9/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import Foundation
import os.log

enum SubProcessIllegalStateError: Error, LocalizedError {
	case alreadyStarted, notStarted
	case openPtyFailed(errno: errno_t)
	case loginTtyFailed(errno: errno_t)
	case forkFailed(errno: errno_t)
	case deallocatedWhileRunning

	private func errorString(errno: errno_t) -> String {
		if let string = strerror(errno) {
			return String(cString: string)
		}
		return String(format: .localize("Unknown (%i)"), errno)
	}

	var errorDescription: String? {
		switch self {
		case .alreadyStarted, .notStarted, .deallocatedWhileRunning:
			return .localize("Internal state error")

		case .openPtyFailed(let errno):
			return String(format: .localize("Couldn’t initialize a terminal. %@"), errorString(errno: errno))

		case .loginTtyFailed(let errno):
			return String(format: .localize("Couldn’t prepare terminal for logging in. %@"), errorString(errno: errno))

		case .forkFailed(let errno):
			return String(format: .localize("Couldn’t start a terminal process. %@"), errorString(errno: errno))
		}
	}
}

enum SubProcessIOError: Error {
	case readFailed(errno: errno_t?)
	case writeFailed(errno: errno_t?)
}

protocol SubProcessDelegate: AnyObject {
	func subProcessDidConnect()
	func subProcess(didReceiveData data: [UTF8Char])
	func subProcess(didDisconnectWithError error: Error?)
	func subProcess(didReceiveError error: Error)
}

class SubProcess {

	private static let loginHelper: String = Bundle.main.path(forAuxiliaryExecutable: "NewTermLoginHelper")!

	private static let loginIsShell: Bool = {
		#if targetEnvironment(simulator)
		true
		#else
		// TODO: Temporary workaround for XinaA15
		(try? URL(fileURLWithPath: "/var/Liy/xina").checkResourceIsReachable()) == true
		#endif
	}()

	private static let login: String = {
		#if targetEnvironment(simulator)
		return "/bin/zsh"
		#elseif targetEnvironment(macCatalyst)
		return "/usr/bin/login"
		#else
		// TODO: Temporary workaround for XinaA15
		if loginIsShell {
			return "/var/jb/bin/zsh"
		}
		return ["/var/jb/usr/bin/login", "/usr/bin/login"]
			.first { (try? URL(fileURLWithPath: $0).checkResourceIsReachable()) == true } ?? "/usr/bin/login"
		#endif
	}()

	private static var loginArgv: [String] {
		#if targetEnvironment(simulator)
		return ["zsh", "--login", "-i"]
		#else
		// TODO: Temporary workaround for XinaA15
		if loginIsShell {
			return ["zsh", "--login", "-i"]
		}

		// Interestingly, despite what login(1) seems to imply, it still seems we need to manually
		// handle passing the -q (force hush login) flag. iTerm2 does this, so I guess it’s fine?
		let hushLoginURL = URL(fileURLWithPath: homeDirectory)/".hushlogin"
		let hushLogin = (try? hushLoginURL.checkResourceIsReachable()) == true
		return ["login", "-fp\(hushLogin ? "q" : "")", NSUserName(), loginHelper]
		#endif
	}

	private static let baseEnvp: [String] = [
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"TERM_PROGRAM=NewTerm",
		"LC_TERMINAL=NewTerm"
	]

	private static var userPasswd: (homeDirectory: String, shell: String)? {
		var length = sysconf(_SC_GETPW_R_SIZE_MAX)
		if length == -1 {
			length = 4096
		}
		let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: length)
		defer { buffer.deallocate() }

		// The strings in pwd point into buffer, so copy them out before it’s freed.
		var pwd = passwd()
		var result: UnsafeMutablePointer<passwd>?
		guard ie_getpwuid_r(getuid(), &pwd, buffer, length, &result) == 0,
					result != nil,
					pwd.pw_dir != nil,
					pwd.pw_shell != nil else {
			return nil
		}
		return (homeDirectory: String(cString: pwd.pw_dir), shell: String(cString: pwd.pw_shell))
	}

	private static var shell: String {
		userPasswd?.shell ?? "/bin/bash"
	}

	private static var homeDirectory: String {
		userPasswd?.homeDirectory ?? NSHomeDirectory()
	}

	weak var delegate: SubProcessDelegate?

	private var childPID: pid_t?
	private var fileDescriptor: Int32?
	/// Guards `childPID` and `fileDescriptor`, and is held for each write and for the close, so a write
	/// can’t reach the fd number once it’s closed and maybe reused for another file. main, `queue` and
	/// `writeQueue` all use them, and stop() can run on main and `queue` at once.
	private let lock = NSLock()

	private let queue = DispatchQueue(label: "ws.hbang.Terminal.io-queue")
	/// Writes have their own queue: a big paste blocks until the program reads it, and the program
	/// may first need its output read, which happens on `queue`.
	private let writeQueue = DispatchQueue(label: "ws.hbang.Terminal.write-queue")
	private var readSource: DispatchSourceRead?
	private var signalSource: DispatchSourceProcess?

	private let logger = Logger(subsystem: "ws.hbang.Terminal", category: "SubProcess")

	var screenSize = ScreenSize.default {
		didSet { updateWindowSize() }
	}

	func start(initialDirectory: String? = nil) throws {
		if childPID != nil {
			throw SubProcessIllegalStateError.alreadyStarted
		}

		// Initialise the pty
		var windowSize = screenSize.windowSize
		var fds = (primary: Int32(), replica: Int32())
		if openpty(&fds.primary, &fds.replica, nil, nil, &windowSize) != 0 {
			// Opening pty failed.
			let error = errno
			logger.error("openpty() failed: \(error, format: .darwinErrno)")
			throw SubProcessIllegalStateError.openPtyFailed(errno: error)
		}
		// Children get only the replica. If a shell kept another tab's primary open, closing that tab
		// wouldn't hang up its pty.
		_ = fcntl(fds.primary, F_SETFD, FD_CLOEXEC)

		var actions: posix_spawn_file_actions_t!
		posix_spawn_file_actions_init(&actions)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDIN_FILENO)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDERR_FILENO)
		defer { posix_spawn_file_actions_destroy(&actions) }

		// TODO: At some point, come up with some way to keep track of working directory changes.
		// When opening a new tab, we can switch straight to the previous tab’s working directory.
		let argv: [UnsafeMutablePointer<CChar>?]
		if Self.loginIsShell {
			argv = Self.loginArgv.cStringArray
			chdir(initialDirectory ?? Self.homeDirectory)
		} else {
			argv = (Self.loginArgv + [initialDirectory ?? Self.homeDirectory, Self.shell]).cStringArray
		}
		var environment = ProcessInfo.processInfo.environment.map { "\($0)=\($1)" } + Self.baseEnvp
		if let localeCode = localeCode {
			environment.append("LANG=\(localeCode)")
		} else if Self.canLoadLocale("UTF-8") {
			// iOS has no locale for any language, only the UTF-8 character set, so ask for just that.
			// Without it programs fall back to ASCII.
			environment.append("LC_CTYPE=UTF-8")
		}
		let envp = environment.cStringArray

		defer {
			argv.deallocate()
			envp.deallocate()
		}

		var pid = pid_t()
		let result = ie_posix_spawn(&pid, Self.login, &actions, nil, argv, envp)
		close(fds.replica)
		if result != 0 {
			// Fork failed.
			close(fds.primary)
			logger.error("posix_spawn() failed: \(result, format: .darwinErrno)")
			throw SubProcessIllegalStateError.forkFailed(errno: result)
		}

		logger.debug("Process forked: \(pid)")

		// A write holds the lock, so it must not block: when the program isn’t reading, write(data:)
		// waits for room without the lock instead.
		let primary = fds.primary
		if fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK) == -1 {
			let error = errno
			logger.error("Setting non-blocking mode failed: \(error, format: .darwinErrno)")
		}

		lock.lock()
		childPID = pid
		fileDescriptor = primary
		lock.unlock()

		// Go ahead and plug a file handle into the child tty.
		readSource = DispatchSource.makeReadSource(fileDescriptor: primary, queue: queue)
		readSource?.setEventHandler { [weak self] in
			self?.handleRead()
		}
		// Dispatch needs the fd open until the source is cancelled, so it’s closed here.
		readSource?.setCancelHandler { [lock] in
			lock.lock()
			close(primary)
			lock.unlock()
		}
		signalSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
		signalSource?.setEventHandler { [weak self] in
			try? self?.stop()
		}

		readSource?.activate()
		signalSource?.activate()
		delegate!.subProcessDidConnect()
	}

	func stop(fromError: Bool = false) throws {
		// Only one caller gets to tear down, and no write or resize starts on the fd after this.
		lock.lock()
		let childPID = self.childPID
		self.childPID = nil
		fileDescriptor = nil
		lock.unlock()

		guard let childPID = childPID else {
			throw SubProcessIllegalStateError.notStarted
		}

		// Cancel reads first, as they now find no fd and the source would keep firing. Its cancel
		// handler closes the fd.
		readSource?.cancel()
		readSource = nil

		// If process is still running, send it SIGKILL and wait for termination
		if kill(childPID, 0) == 0 {
			kill(childPID, SIGKILL)

			var status = Int32()
			waitpid(childPID, &status, WUNTRACED)

			logger.debug("Process stopped with exit code: \(WEXITSTATUS(status))")
		}

		signalSource?.cancel()
		signalSource = nil

		if !fromError {
			// nil error means disconnected due to user request
			DispatchQueue.main.async {
				self.delegate?.subProcess(didDisconnectWithError: nil)
			}
		}
	}

	private func handleRead() {
		// The fd stays open while this runs: it’s closed on this queue, once the source is cancelled.
		lock.lock()
		let fileDescriptor = self.fileDescriptor
		lock.unlock()
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(BUFSIZ), alignment: MemoryLayout<CChar>.alignment)
		let bytesRead = read(fileDescriptor, buffer, Int(BUFSIZ))
		switch bytesRead {
		case -1:
			let code = errno
			switch code {
			case EAGAIN, EINTR:
				// Ignore, we’ll be called again when the source is ready.
				break

			default:
				// Something is wrong.
				DispatchQueue.main.async {
					self.delegate?.subProcess(didDisconnectWithError: SubProcessIOError.readFailed(errno: code))
				}
			}

		case 0:
			// Zero-length data is an indicator of EOF. This can happen if the user exits the terminal by
			// typing `exit` or ^D, or if there’s a catastrophic failure (e.g. /bin/login is broken).
			try? stop(fromError: false)

		default:
			// Read from output and notify delegate.
			let bytes = buffer.bindMemory(to: UTF8Char.self, capacity: bytesRead)
			let data = Array(UnsafeBufferPointer(start: bytes, count: bytesRead))
			delegate?.subProcess(didReceiveData: data)
		}
		buffer.deallocate()
	}

	func write(data: [UTF8Char]) {
		writeQueue.async {
			data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
				var offset = 0
				while offset < buffer.count {
					// Check the fd and write under the lock, so it can’t be closed in between.
					self.lock.lock()
					guard let fileDescriptor = self.fileDescriptor else {
						self.lock.unlock()
						return
					}
					let written = Darwin.write(fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
					let error = errno
					self.lock.unlock()

					if written < 0 {
						switch error {
						case EINTR:
							continue

						case EAGAIN:
							// The program isn’t reading yet. Wait for room, with a timeout because a close
							// doesn’t wake poll().
							var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
							poll(&pollDescriptor, 1, 100)
							continue

						default:
							// EIO once the program has gone.
							return
						}
					}
					offset += written
				}
			}
		}
	}

	private var localeCode: String? {
		// Try and find a locale suitable for the user. Use en_US.UTF-8 as fallback, or nothing if that
		// won’t load either (as on iOS): readline (so bash) crashes on a LANG that setlocale() can’t
		// load.
		// TODO: There has to be a better way to get a gettext locale out of the Apple locale. For
		// instance, a phone set to Simplified Chinese but a region of Australia will only have the
		// language zh_AU… which isn’t a thing. But gettext only has languages in country pairs, no
		// safe generic fallbacks exist, like zh-Hans in this case.
		var languages = Locale.preferredLanguages
		let preferredLocale = Preferences.shared.preferredLocale
		if preferredLocale != "",
			 Locale(identifier: preferredLocale).languageCode != nil {
			languages.insert(preferredLocale, at: 0)
		}

		for language in languages {
			let locale = Locale(identifier: language)
			if let languageCode = locale.languageCode,
				 let regionCode = locale.regionCode {
				let identifier = "\(languageCode)_\(regionCode).UTF-8"
				if Self.canLoadLocale(identifier) {
					return identifier
				}
			}
		}
		return Self.canLoadLocale("en_US.UTF-8") ? "en_US.UTF-8" : nil
	}

	/// Asks libc itself, which is what the shell will do with LANG. Its folder in /usr/share/locale
	/// existing isn’t enough.
	private static func canLoadLocale(_ identifier: String) -> Bool {
		guard let locale = newlocale(LC_CTYPE_MASK, identifier, nil) else {
			return false
		}
		freelocale(locale)
		return true
	}

	private func updateWindowSize() {
		lock.lock()
		defer { lock.unlock() }
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		var windowSize = screenSize.windowSize
		if ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == -1 {
			let error = errno
			logger.error("Setting screen size failed: \(error, format: .darwinErrno)")
		}
	}

	deinit {
		if childPID != nil {
			logger.error("Illegal state - SubProcess deallocated while still running")
		}

		try? stop(fromError: true)
	}

}
