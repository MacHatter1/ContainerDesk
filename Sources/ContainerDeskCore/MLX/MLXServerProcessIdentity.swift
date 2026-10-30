import Darwin
import Foundation

enum MLXServerProcessIdentity {
    static func isServer(arguments: [String]) -> Bool {
        guard let executable = arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return false }
        var command = Array(arguments.dropFirst())
        if executable.hasPrefix("python") {
            while let flag = command.first, ["-u", "-I", "-E", "-s", "-S", "-B", "-O", "-OO"].contains(flag) { command.removeFirst() }
            if command.first == "-m" {
                command.removeFirst()
                return command.first == "mlx_lm.server" || command.starts(with: ["mlx_lm", "server"])
            }
            guard let script = command.first else { return false }
            return isServer(arguments: [script] + command.dropFirst())
        }
        return executable == "mlx_lm.server" || (executable == "mlx_lm" && command.first == "server")
    }

    /// Read only argv from KERN_PROCARGS2; environment data is neither decoded nor retained.
    static func arguments(processID: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return [] }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return [] }
        data.count = size
        return decodeArguments(data)
    }

    static func decodeArguments(_ data: Data) -> [String] {
        guard data.count > 4 else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4_096 else { return [] }
        var cursor = 4
        // Executable path is followed by padding, then argc NUL-terminated argv strings.
        while cursor < data.count, data[cursor] != 0 { cursor += 1 }
        while cursor < data.count, data[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0),
                  let argument = String(data: data[cursor..<end], encoding: .utf8) else { return [] }
            result.append(argument)
            cursor = end + 1
        }
        return result
    }
}
