import AppKit
import Darwin
import Foundation
import ServiceManagement

let signalToIgnore: [Int32] = [
    SIGHUP, SIGINT, SIGQUIT,
    SIGABRT, SIGKILL, SIGALRM,
    SIGTERM,
]
signalToIgnore.forEach { signal($0, SIG_IGN) }

// MARK: - 命令行参数解析
let args = CommandLine.arguments
let skipLaunchAgents = args.contains("--no-launch-agents")
let skipLoginItems = args.contains("--no-login-items")
let showHelp = args.contains("--help") || args.contains("-h")

if showHelp {
    print("""
    FixTim - macOS Soft Restart Tool
    
    Usage: fixtim [options]
    
    Options:
      --no-launch-agents    Skip reloading LaunchAgents
      --no-login-items      Skip launching Login Items
      --help, -h            Show this help message
    
    """)
    exit(0)
}

let documentDir = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
).first!
let dockLayoutBackup = documentDir
    .appendingPathComponent(".com.apple.dock.backup")
    .appendingPathExtension("plist")

// 收集重启前的状态
print("[*] scanning app list...")
let appList = listApplications()

var launchAgentPlists: [URL] = []
if !skipLaunchAgents {
    print("[*] scanning LaunchAgents directory...")
    launchAgentPlists = listAllLaunchAgentPlists()
    print("[*] found \(launchAgentPlists.count) LaunchAgent plist files")
}

var loginItemsList: [LoginItemInfo] = []
if !skipLoginItems {
    print("[*] scanning Login Items via System Events...")
    loginItemsList = listLoginItemsViaAppleScript()
    print("[*] found \(loginItemsList.count) Login Items")
}

print("[*] backing up Dock layout to \(dockLayoutBackup.path)")
AuxiliaryExecute.spawn(
    command: "/usr/bin/defaults",
    args: [
        "export",
        "com.apple.dock.plist",
        dockLayoutBackup.path,
    ]
)
sleep(1)

print("[*] starting restart!")
executeRestart()
sleep(5)

// 重新启动应用
print("[*] resume apps...")
let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.addsToRecentItems = false
config.hides = true
appList.forEach {
    print("[*] launching app at \($0.path)")
    NSWorkspace.shared.openApplication(at: $0, configuration: config)
}
sleep(1)

// 重新加载 LaunchAgents
if !skipLaunchAgents && !launchAgentPlists.isEmpty {
    print("[*] reloading \(launchAgentPlists.count) LaunchAgents...")
    reloadAllLaunchAgents(launchAgentPlists)
    sleep(1)
}

// 启动 Login Items
if !skipLoginItems && !loginItemsList.isEmpty {
    print("[*] launching Login Items...")
    launchLoginItems(loginItemsList)
    sleep(1)
}

print("[*] restoring Dock layout...")
AuxiliaryExecute.spawn(
    command: "/usr/bin/defaults",
    args: [
        "import",
        "com.apple.dock.plist",
        dockLayoutBackup.path,
    ]
)
AuxiliaryExecute.spawn(
    command: "/usr/bin/killall",
    args: ["-9", "Dock"]
)

exit(0)

// Auxiliary Execute

import Foundation

/// Execute command or shell with posix, shared with AuxiliaryExecute.local
public class AuxiliaryExecute {
    /// we do not recommend you to subclass this singleton
    public static let local = AuxiliaryExecute()

    // if binary not found when you call the shell api
    // we will take some time to rebuild the bianry table each time
    // -->>> this is a time-heavy-task
    // so use binaryLocationFor(command:) to cache it if needed

    // system path
    var currentPath: [String] = []
    // system binary table
    var binaryTable: [String: String] = [:]

    // for you to put your own search path
    var extraSearchPath: [String] = []
    // for you to set your own binary table and will be used firstly
    // if you set nil here
    // -> we will return nil even the binary found in system path
    var overwriteTable: [String: String?] = [:]

    // this value is used when providing 0 or negative timeout paramete
    static let maxTimeoutValue: Double = 2_147_483_647

    /// when reading from file pipe, must called from async queue
    static let pipeControlQueue = DispatchQueue(
        label: "wiki.qaq.AuxiliaryExecute.pipeRead",
        attributes: .concurrent
    )

    /// when killing process or monitoring events from process, must called from async queue
    /// we are making this queue serial queue so won't called at the same time when timeout
    static let processControlQueue = DispatchQueue(
        label: "wiki.qaq.AuxiliaryExecute.processControl",
        attributes: []
    )

    /// used for setting binary table, avoid crash
    let lock = NSLock()

    /// nope!
    private init() {
        // no need to setup binary table
        // we will make call to it when you call the shell api
        // if you only use the spawn api
        // we don't need to setup the hole table cause it‘s time-heavy-task
    }

    /// Execution Error, do the localization your self
    public enum ExecuteError: Error, LocalizedError, Codable {
        // not found in path
        case commandNotFound
        // invalid, may be missing, wrong permission or any other reason
        case commandInvalid
        // fcntl failed
        case openFilePipeFailed
        // posix failed
        case posixSpawnFailed
        // waitpid failed
        case waitPidFailed
        // timeout when execute
        case timeout
    }

    /// Execution Receipt
    public struct ExecuteReceipt: Codable {
        // exit code, usually 0 - 255 by system
        // -1 means something bad happened, set by us for convince
        public let exitCode: Int
        // process pid that was when it is alive
        // -1 means spawn failed in some situation
        public let pid: Int
        // wait result for final waitpid inside block at
        // processSource - eventMask.exit, usually is pid
        // -1 for other cases
        public let wait: Int
        // any error from us, not the command it self
        // DOES NOT MEAN THAT THE COMMAND DONE WELL
        public let error: ExecuteError?
        // stdout
        public let stdout: String
        // stderr
        public let stderr: String

        /// General initialization of receipt object
        /// - Parameters:
        ///   - exitCode: code when process exit
        ///   - pid: pid when process alive
        ///   - wait: wait result on waitpid
        ///   - error: error if any
        ///   - stdout: stdout
        ///   - stderr: stderr
        init(
            exitCode: Int,
            pid: Int,
            wait: Int,
            error: AuxiliaryExecute.ExecuteError?,
            stdout: String,
            stderr: String
        ) {
            self.exitCode = exitCode
            self.pid = pid
            self.wait = wait
            self.error = error
            self.stdout = stdout
            self.stderr = stderr
        }

        /// Template for making failure receipt
        /// - Parameters:
        ///   - exitCode: default -1
        ///   - pid: default -1
        ///   - wait: default -1
        ///   - error: error
        ///   - stdout: default empty
        ///   - stderr: default empty
        static func failure(
            exitCode: Int = -1,
            pid: Int = -1,
            wait: Int = -1,
            error: AuxiliaryExecute.ExecuteError?,
            stdout: String = "",
            stderr: String = ""
        ) -> ExecuteReceipt {
            .init(
                exitCode: exitCode,
                pid: pid,
                wait: wait,
                error: error,
                stdout: stdout,
                stderr: stderr
            )
        }
    }
}

//
//  AuxiliaryExecute+Spawn.swift
//  AuxiliaryExecute
//
//  Created by Lakr Aream on 2021/12/6.
//

import Foundation

public extension AuxiliaryExecute {
    /// call posix spawn to begin execute
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - output: a block call from pipeControlQueue in background when buffer from stdout or stderr available for read
    /// - Returns: execution receipt, see it's definition for details
    @discardableResult
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        output: ((String) -> Void)? = nil
    )
        -> ExecuteReceipt
    {
        let outputLock = NSLock()
        let result = spawn(
            command: command,
            args: args,
            environment: environment,
            timeout: timeout,
            setPid: setPid
        ) { str in
            outputLock.lock()
            output?(str)
            outputLock.unlock()
        } stderrBlock: { str in
            outputLock.lock()
            output?(str)
            outputLock.unlock()
        }
        return result
    }

    /// call posix spawn to begin execute and block until the process exits
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - stdout: a block call from pipeControlQueue in background when buffer from stdout available for read
    ///   - stderr: a block call from pipeControlQueue in background when buffer from stderr available for read
    /// - Returns: execution receipt, see it's definition for details
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        stdoutBlock: ((String) -> Void)? = nil,
        stderrBlock: ((String) -> Void)? = nil
    ) -> ExecuteReceipt {
        let sema = DispatchSemaphore(value: 0)
        var receipt: ExecuteReceipt!
        spawn(
            command: command,
            args: args,
            environment: environment,
            timeout: timeout,
            setPid: setPid,
            stdoutBlock: stdoutBlock,
            stderrBlock: stderrBlock
        ) {
            receipt = $0
            sema.signal()
        }
        sema.wait()
        return receipt
    }

    /// call posix spawn to begin execute
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - setPid: called sync when pid available
    ///   - stdoutBlock: a block call from pipeControlQueue in background when buffer from stdout available for read
    ///   - stderrBlock: a block call from pipeControlQueue in background when buffer from stderr available for read
    ///   - completionBlock: a block called from processControlQueue or current queue when the process is finished or an error occurred
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        stdoutBlock: ((String) -> Void)? = nil,
        stderrBlock: ((String) -> Void)? = nil,
        completionBlock: ((ExecuteReceipt) -> Void)? = nil
    ) {
        // MARK: PREPARE FILE PIPE -

        var pipestdout: [Int32] = [0, 0]
        var pipestderr: [Int32] = [0, 0]

        let bufsiz = Int(exactly: BUFSIZ) ?? 65535

        pipe(&pipestdout)
        pipe(&pipestderr)

        guard fcntl(pipestdout[0], F_SETFL, O_NONBLOCK) != -1 else {
            let receipt = ExecuteReceipt.failure(error: .openFilePipeFailed)
            completionBlock?(receipt)
            return
        }
        guard fcntl(pipestderr[0], F_SETFL, O_NONBLOCK) != -1 else {
            let receipt = ExecuteReceipt.failure(error: .openFilePipeFailed)
            completionBlock?(receipt)
            return
        }

        // MARK: PREPARE FILE ACTION -

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, pipestdout[0])
        posix_spawn_file_actions_addclose(&fileActions, pipestderr[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipestdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipestderr[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipestdout[1])
        posix_spawn_file_actions_addclose(&fileActions, pipestderr[1])

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        // MARK: PREPARE ENV -

        var realEnvironmentBuilder: [String] = []
        // before building the environment, we need to read from the existing environment
        do {
            var envBuilder = [String: String]()
            var currentEnv = environ
            while let rawStr = currentEnv.pointee {
                defer { currentEnv += 1 }
                // get the env
                let str = String(cString: rawStr)
                guard let key = str.components(separatedBy: "=").first else {
                    continue
                }
                if !(str.count >= "\(key)=".count) {
                    continue
                }
                // this is to aviod any problem with mua=nya=nya= that ending with =
                let value = String(str.dropFirst("\(key)=".count))
                envBuilder[key] = value
            }
            // now, let's overwrite the environment specified in parameters
            for (key, value) in environment {
                envBuilder[key] = value
            }
            // now, package those items
            for (key, value) in envBuilder {
                realEnvironmentBuilder.append("\(key)=\(value)")
            }
        }
        // making it a c shit
        let realEnv: [UnsafeMutablePointer<CChar>?] = realEnvironmentBuilder.map { $0.withCString(strdup) }
        defer { for case let env? in realEnv { free(env) } }

        // MARK: PREPARE ARGS -

        let args = [command] + args
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) }
        defer { for case let arg? in argv { free(arg) } }

        // MARK: NOW POSIX_SPAWN -

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, command, &fileActions, nil, argv + [nil], realEnv + [nil])
        if spawnStatus != 0 {
            let receipt = ExecuteReceipt.failure(error: .posixSpawnFailed)
            completionBlock?(receipt)
            return
        }

        setPid?(pid)

        close(pipestdout[1])
        close(pipestderr[1])

        var stdoutStr = ""
        var stderrStr = ""

        // MARK: OUTPUT BRIDGE -

        let stdoutSource = DispatchSource.makeReadSource(fileDescriptor: pipestdout[0], queue: pipeControlQueue)
        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: pipestderr[0], queue: pipeControlQueue)

        let stdoutSem = DispatchSemaphore(value: 0)
        let stderrSem = DispatchSemaphore(value: 0)

        stdoutSource.setCancelHandler {
            close(pipestdout[0])
            stdoutSem.signal()
        }
        stderrSource.setCancelHandler {
            close(pipestderr[0])
            stderrSem.signal()
        }

        stdoutSource.setEventHandler {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buffer.deallocate() }
            let bytesRead = read(pipestdout[0], buffer, bufsiz)
            guard bytesRead > 0 else {
                if bytesRead == -1, errno == EAGAIN {
                    return
                }
                stdoutSource.cancel()
                return
            }

            let array = Array(UnsafeBufferPointer(start: buffer, count: bytesRead)) + [UInt8(0)]
            array.withUnsafeBufferPointer { ptr in
                let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                stdoutStr += str
                stdoutBlock?(str)
            }
        }
        stderrSource.setEventHandler {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buffer.deallocate() }

            let bytesRead = read(pipestderr[0], buffer, bufsiz)
            guard bytesRead > 0 else {
                if bytesRead == -1, errno == EAGAIN {
                    return
                }
                stderrSource.cancel()
                return
            }

            let array = Array(UnsafeBufferPointer(start: buffer, count: bytesRead)) + [UInt8(0)]
            array.withUnsafeBufferPointer { ptr in
                let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                stderrStr += str
                stderrBlock?(str)
            }
        }

        stdoutSource.resume()
        stderrSource.resume()

        // MARK: WAIT + TIMEOUT CONTROL -

        let realTimeout = timeout > 0 ? timeout : maxTimeoutValue
        let wallTimeout = DispatchTime.now() + (
            TimeInterval(exactly: realTimeout) ?? maxTimeoutValue
        )
        var status: Int32 = 0
        var wait: pid_t = 0
        var isTimeout = false

        let timerSource = DispatchSource.makeTimerSource(flags: [], queue: processControlQueue)
        timerSource.setEventHandler {
            isTimeout = true
            kill(pid, SIGKILL)
        }

        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: processControlQueue)
        processSource.setEventHandler {
            wait = waitpid(pid, &status, 0)

            processSource.cancel()
            timerSource.cancel()

            stdoutSem.wait()
            stderrSem.wait()

            // by using exactly method, we won't crash it!
            let receipt = ExecuteReceipt(
                exitCode: Int(exactly: status) ?? -1,
                pid: Int(exactly: pid) ?? -1,
                wait: Int(exactly: wait) ?? -1,
                error: isTimeout ? .timeout : nil,
                stdout: stdoutStr,
                stderr: stderrStr
            )
            completionBlock?(receipt)
        }
        processSource.resume()

        // timeout control
        timerSource.schedule(deadline: wallTimeout)
        timerSource.resume()
    }
}

// ldrestart

@discardableResult func executeRestart() -> Int32 {
    let request = launch_data_new_string(LAUNCH_KEY_GETJOBS)
    let response = launch_msg(request)
    launch_data_free(request)
    guard launch_data_get_type(response) == LAUNCH_DATA_DICTIONARY else {
        return EX_SOFTWARE
    }
    let iterateBlock: @convention(c) (
        OpaquePointer,
        UnsafePointer<Int8>,
        UnsafeMutableRawPointer?
    ) -> Void = { value, name, _ in
        guard let value = value as? launch_data_t,
              let name = name as? UnsafePointer<Int8>,
              launch_data_get_type(value) == LAUNCH_DATA_DICTIONARY,
              let integer = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PID),
              launch_data_get_type(integer) == LAUNCH_DATA_INTEGER,
              let string = launch_data_dict_lookup(value, LAUNCH_JOBKEY_LABEL),
              launch_data_get_type(string) == LAUNCH_DATA_STRING
        else { return }

        let label = launch_data_get_string(string)
        let pid = launch_data_get_integer(integer)

        guard pid != getpid() else { return }
        guard kill(pid_t(pid), 0) != -1 else { return }

        print("[*] terminating process \(pid)")

        let stop = launch_data_alloc(LAUNCH_DATA_DICTIONARY)
        launch_data_dict_insert(stop, string, LAUNCH_KEY_STOPJOB)
        let result = launch_msg(stop)
        if launch_data_get_type(result) != LAUNCH_DATA_ERRNO {
            let labelString = String(cString: label)
            print(labelString)
        } else {
            let number = launch_data_get_errno(result)
            let labelString = String(cString: label)
            let errorString = String(cString: strerror(number))
            print("[E] \(labelString): \(errorString)")
        }
    }
    launch_data_dict_iterate(response, iterateBlock, nil)
    return EX_OK
}

// list apps

func listApplications() -> Set<URL> {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var bufferSize = 0
    if sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) < 0 { return [] }
    let entryCount = bufferSize / MemoryLayout<kinfo_proc>.stride

    var procList: UnsafeMutablePointer<kinfo_proc>?
    procList = UnsafeMutablePointer.allocate(capacity: bufferSize)
    defer { procList?.deallocate() }

    if sysctl(&mib, UInt32(mib.count), procList, &bufferSize, nil, 0) < 0 { return [] }

    var res = Set<URL>()
    // 修复: 使用 ..< 而不是 ... 防止数组越界
    for index in 0 ..< entryCount {
        guard let pid = procList?[index].kp_proc.p_pid,
              pid != 0,
              pid != getpid()
        else { continue }
        var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
        proc_pidpath(pid, &buf, UInt32(PROC_PIDPATHINFO_SIZE))
        let path = String(cString: buf)

        guard path.contains(".app") else { continue }

        // 扩展: 支持任意路径的 .app，不再限制于特定目录
        var url = URL(fileURLWithPath: path)
        guard url.pathComponents.count > 0 else { continue }
        var findIdx = 0
        for idx in 0 ..< url.pathComponents.count {
            findIdx = idx
            if url.pathComponents[idx].hasSuffix(".app") { break }
        }
        let deleteCount = url.pathComponents.count - findIdx - 1
        if deleteCount > 0 {
            for _ in 0 ..< deleteCount { url.deleteLastPathComponent() }
        }
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let bid = bundle.bundleIdentifier,
              !res.contains(bundle.bundleURL)
        else { continue }
        print("[*] found \(bid) at \(bundle.bundleURL.path)")
        res.insert(bundle.bundleURL)
    }
    return res
}

// MARK: - LaunchAgents 支持
/// 获取用户 LaunchAgents 目录中的所有 plist 文件
func listAllLaunchAgentPlists() -> [URL] {
    let userLaunchAgentsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: userLaunchAgentsPath,
        includingPropertiesForKeys: nil
    ) else {
        print("[!] Cannot read LaunchAgents directory at \(userLaunchAgentsPath.path)")
        return []
    }
    
    let plists = contents.filter { $0.pathExtension == "plist" }
    for plist in plists {
        print("[*] found LaunchAgent: \(plist.lastPathComponent)")
    }
    return plists
}

/// 重新加载所有 LaunchAgents
func reloadAllLaunchAgents(_ plists: [URL]) {
    let uid = getuid()
    let domain = "gui/\(uid)"
    
    for plistURL in plists {
        let plistPath = plistURL.path
        let name = plistURL.deletingPathExtension().lastPathComponent
        
        print("[*] reloading LaunchAgent: \(name)")
        
        // 先 bootout（可能失败，忽略错误）
        AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootout", domain, plistPath]
        )
        
        usleep(50_000) // 50ms
        
        // 然后 bootstrap
        let result = AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootstrap", domain, plistPath]
        )
        
        if result.exitCode != 0 {
            // 如果 bootstrap 失败，尝试旧式 load
            let loadResult = AuxiliaryExecute.spawn(
                command: "/bin/launchctl",
                args: ["load", "-w", plistPath]
            )
            if loadResult.exitCode != 0 {
                print("[!] failed to load \(name)")
            }
        }
    }
}

/// 获取当前已加载的用户级 LaunchAgents（旧版函数，保留兼容性）
func listLoadedLaunchAgents() -> [String] {
    let userLaunchAgentsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    
    let receipt = AuxiliaryExecute.spawn(
        command: "/bin/launchctl",
        args: ["list"]
    )
    
    guard receipt.exitCode == 0 else { return [] }
    
    let lines = receipt.stdout.components(separatedBy: "\n")
    var agents: [String] = []
    
    for line in lines {
        let components = line.components(separatedBy: "\t")
        guard components.count >= 3 else { continue }
        let label = components[2]
        
        guard !label.hasPrefix("com.apple.") else { continue }
        
        let plistPath = userLaunchAgentsPath.appendingPathComponent("\(label).plist")
        if FileManager.default.fileExists(atPath: plistPath.path) {
            agents.append(label)
        }
    }
    
    return agents
}

/// 重新加载指定的 LaunchAgents（旧版函数）
func reloadLaunchAgents(_ agents: [String]) {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    
    for agent in agents {
        let plistPath = "\(homeDir)/Library/LaunchAgents/\(agent).plist"
        
        guard FileManager.default.fileExists(atPath: plistPath) else {
            print("[!] LaunchAgent plist not found: \(plistPath)")
            continue
        }
        
        print("[*] reloading LaunchAgent: \(agent)")
        
        let uid = getuid()
        let domain = "gui/\(uid)"
        
        AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootout", domain, plistPath]
        )
        
        usleep(100_000)
        
        let result = AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootstrap", domain, plistPath]
        )
        
        if result.exitCode != 0 {
            print("[!] bootstrap failed, trying legacy load...")
            AuxiliaryExecute.spawn(
                command: "/bin/launchctl",
                args: ["load", "-w", plistPath]
            )
        }
    }
}

// MARK: - Login Items 支持

struct LoginItemInfo {
    let name: String
    let path: String?
}

/// 使用 AppleScript 通过 System Events 获取登录项列表
func listLoginItemsViaAppleScript() -> [LoginItemInfo] {
    // 获取登录项名称列表
    let nameScript = """
    tell application "System Events"
        get the name of every login item
    end tell
    """
    
    let nameResult = AuxiliaryExecute.spawn(
        command: "/usr/bin/osascript",
        args: ["-e", nameScript]
    )
    
    guard nameResult.exitCode == 0 else {
        print("[!] Failed to get login items via AppleScript")
        return []
    }
    
    let namesString = nameResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !namesString.isEmpty else {
        print("[*] No login items found")
        return []
    }
    
    // 解析名称列表（格式: "App1, App2, App3"）
    let names = namesString.components(separatedBy: ", ")
    var items: [LoginItemInfo] = []
    
    for name in names {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { continue }
        
        print("[*] found Login Item: \(trimmedName)")
        items.append(LoginItemInfo(name: trimmedName, path: nil))
    }
    
    return items
}

/// 启动所有登录项（后台启动，使用 open -a -g 命令）
func launchAllLoginItems(_ items: [LoginItemInfo]) {
    for item in items {
        print("[*] launching Login Item in background: \(item.name)")
        
        // 使用 open -a -g 命令后台启动应用（-g 表示不将应用带到前台）
        let result = AuxiliaryExecute.spawn(
            command: "/usr/bin/open",
            args: ["-a", "-g", item.name]
        )
        
        if result.exitCode != 0 {
            // 如果直接用名称失败，尝试在 /Applications 中查找
            let appPath = "/Applications/\(item.name).app"
            let result2 = AuxiliaryExecute.spawn(
                command: "/usr/bin/open",
                args: ["-g", appPath]
            )
            
            if result2.exitCode != 0 {
                print("[!] failed to launch \(item.name)")
            }
        }
    }
}

/// 旧版函数（保留兼容性，但不再使用）
@available(macOS 13.0, *)
func listLoginItems() -> [LoginItemInfo] {
    // 直接使用 AppleScript 方式，更可靠
    return listLoginItemsViaAppleScript()
}

func launchLoginItems(_ items: [LoginItemInfo]) {
    launchAllLoginItems(items)
}
