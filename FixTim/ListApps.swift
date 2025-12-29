//
//  ListApps.swift
//  JustFixItX
//
//  Created by 秋星桥 on 2024/2/6.
//  Enhanced with LaunchAgents and Login Items support
//

import AppKit
import AuxiliaryExecute
import Darwin
import Foundation
import ServiceManagement

// MARK: - 运行中的应用列表

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

/// 用户级 LaunchAgents 目录
private let userLaunchAgentsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents")

/// 获取用户 LaunchAgents 目录中的所有 plist 文件
func listAllLaunchAgentPlists() -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: userLaunchAgentsPath,
        includingPropertiesForKeys: nil
    ) else {
        print("[!] Cannot read LaunchAgents directory")
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

/// 获取用户 LaunchAgents 目录中的所有 plist（旧版函数）
func listUserLaunchAgentPlists() -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: userLaunchAgentsPath,
        includingPropertiesForKeys: nil
    ) else { return [] }
    
    return contents.filter { $0.pathExtension == "plist" }
}

/// 重新加载指定的 LaunchAgents
func reloadLaunchAgents(_ agents: [String]) {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    
    for agent in agents {
        let plistPath = "\(homeDir)/Library/LaunchAgents/\(agent).plist"
        
        guard FileManager.default.fileExists(atPath: plistPath) else {
            print("[!] LaunchAgent plist not found: \(plistPath)")
            continue
        }
        
        print("[*] reloading LaunchAgent: \(agent)")
        
        // 使用 launchctl bootout/bootstrap (macOS 10.10+)
        // 或者 unload/load 作为备选
        let uid = getuid()
        let domain = "gui/\(uid)"
        
        // 先尝试 bootout（可能失败，忽略错误）
        AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootout", domain, plistPath]
        )
        
        // 等待一小段时间
        usleep(100_000) // 100ms
        
        // 然后 bootstrap
        let result = AuxiliaryExecute.spawn(
            command: "/bin/launchctl",
            args: ["bootstrap", domain, plistPath]
        )
        
        if result.exitCode != 0 {
            // 如果 bootstrap 失败，尝试旧式 load
            print("[!] bootstrap failed, trying legacy load...")
            AuxiliaryExecute.spawn(
                command: "/bin/launchctl",
                args: ["load", "-w", plistPath]
            )
        }
    }
}

// MARK: - Login Items 支持

/// Login Items 信息结构
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

/// 兼容性别名
@available(macOS 13.0, *)
func listLoginItems() -> [LoginItemInfo] {
    return listLoginItemsViaAppleScript()
}

func launchLoginItems(_ items: [LoginItemInfo]) {
    launchAllLoginItems(items)
}
