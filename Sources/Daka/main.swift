import AppKit
import DakaCore
import Darwin
import Foundation

if CommandLine.arguments.contains("--show")
    || CommandLine.arguments.contains("--show-settings")
{
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("local.daka.menu.show"),
        object: CommandLine.arguments.contains("--show-settings")
            ? DakaDashboardSection.settings.rawValue
            : DakaDashboardSection.today.rawValue,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
    CommandLine.arguments.indices.contains(previewIndex + 1)
{
    let outputURL = URL(
        fileURLWithPath: NSString(
            string: CommandLine.arguments[previewIndex + 1]
        ).expandingTildeInPath
    )
    do {
        let section: DakaDashboardSection
        if CommandLine.arguments.contains("--preview-records") {
            section = .records
        } else if CommandLine.arguments.contains("--preview-trends") {
            section = .trends
        } else if CommandLine.arguments.contains("--preview-monthly") {
            section = .monthly
        } else if CommandLine.arguments.contains("--preview-settings") {
            section = .settings
        } else {
            section = .today
        }
        let settingsSection: DakaSettingsSection
        if CommandLine.arguments.contains("--preview-conditions") {
            settingsSection = .conditions
        } else if CommandLine.arguments.contains("--preview-reminders") {
            settingsSection = .reminders
        } else if CommandLine.arguments.contains("--preview-runtime") {
            settingsSection = .runtime
        } else {
            settingsSection = .goals
        }
        let records: [DailyRecord]
        let config: AppConfig
        if CommandLine.arguments.contains("--demo-preview") {
            let fixtures = DakaPreviewFixtures.make()
            records = fixtures.records
            config = fixtures.config
        } else {
            let store = try DakaStore(paths: DakaPaths())
            records = try store.loadRecords()
            config = try store.loadConfig()
        }
        try renderDakaDashboardPreview(
            records: records,
            config: config,
            section: section,
            settingsSection: settingsSection,
            outputURL: outputURL
        )
        print(outputURL.path)
        exit(0)
    } catch {
        fputs("Daka preview failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private enum SingleInstanceLockError: Error {
    case alreadyRunning
    case systemError(path: String, code: Int32)
}

private final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init(path: String = "/tmp/daka-\(getuid()).lock") throws {
        fileDescriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw SingleInstanceLockError.systemError(path: path, code: errno)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(fileDescriptor)
            if lockError == EWOULDBLOCK {
                throw SingleInstanceLockError.alreadyRunning
            }
            throw SingleInstanceLockError.systemError(path: path, code: lockError)
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

private let singleInstanceLock: SingleInstanceLock
do {
    singleInstanceLock = try SingleInstanceLock()
} catch SingleInstanceLockError.alreadyRunning {
    NSLog("Daka is already running; exiting duplicate instance.")
    exit(0)
} catch SingleInstanceLockError.systemError(let path, let code) {
    NSLog("Daka failed to acquire instance lock at \(path): \(String(cString: strerror(code)))")
    exit(1)
} catch {
    NSLog("Daka failed to acquire instance lock: \(error)")
    exit(1)
}

withExtendedLifetime(singleInstanceLock) {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
