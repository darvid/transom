import Darwin
import Foundation

enum ProcessArguments {
    static func arguments(for pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return []
        }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var result: [String] = []
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index > start {
                result.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            }
            while index < size, buffer[index] == 0 { index += 1 }
        }
        return result
    }

    static func profile(
        from arguments: [String],
        browser: InstalledBrowser
    ) -> BrowserProfile? {
        switch browser.family {
        case .chromium:
            guard let argument = arguments.first(where: { $0.hasPrefix("--profile-directory=") }) else {
                return nil
            }
            let id = String(argument.dropFirst("--profile-directory=".count))
            return browser.profiles.first { $0.id == id }
        case .firefox:
            for (index, argument) in arguments.enumerated() {
                guard argument == "-P" || argument == "--profile" else { continue }
                guard arguments.indices.contains(index + 1) else { continue }
                let value = arguments[index + 1]
                return browser.profiles.first {
                    $0.id == value || $0.name == value || $0.directory?.path == value
                }
            }
            return nil
        }
    }
}
