import Cocoa
import Foundation

public final class SingleInstanceManager {
    public static let shared = SingleInstanceManager()
    
    private static let notificationName = Notification.Name("org.futo.voiceboy.reopen")
    private var lockFd: Int32 = -1
    
    private init() {}
    
    public func acquireSingleInstanceLock() -> Bool {
        let currentPID = getpid()
        let bundleID = Bundle.main.bundleIdentifier ?? "org.futo.voiceboy"
        
        // 1. Check LaunchServices for another running instance of VoiceBoy
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in runningApps {
            if app.processIdentifier != currentPID {
                notifyAndActivateExisting(app: app)
                return false
            }
        }
        
        // 2. Kernel-level flock lock file (protects direct binary launches and command-line GUI invocations)
        let lockFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("org.futo.voiceboy.instance.lock")
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        if fd < 0 {
            return true
        }
        
        let rc = flock(fd, LOCK_EX | LOCK_NB)
        if rc != 0 {
            // Another instance holds the lock
            var pidBuffer = [CChar](repeating: 0, count: 32)
            let bytesRead = read(fd, &pidBuffer, pidBuffer.count - 1)
            close(fd)
            
            if bytesRead > 0 {
                let pidStr = String(cString: pidBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(pidStr), let existingApp = NSRunningApplication(processIdentifier: pid) {
                    notifyAndActivateExisting(app: existingApp)
                    return false
                }
            }
            
            // Broadcast reopen request across processes
            DistributedNotificationCenter.default().postNotificationName(
                Self.notificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return false
        }
        
        // Successfully acquired lock — persist file descriptor across process lifetime
        self.lockFd = fd
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pidString = "\(currentPID)\n"
        pidString.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        
        // Listen for reopen requests from duplicate launch attempts
        DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                AppDelegate.shared?.showMainWindow()
            }
        }
        
        return true
    }
    
    private func notifyAndActivateExisting(app: NSRunningApplication) {
        app.activate(options: [.activateIgnoringOtherApps])
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
