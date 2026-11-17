import Darwin
import Foundation

/// A helper process with a stdin pipe and one combined stdout/stderr pipe, spawned with
/// posix_spawn. It leads its own process group, so a signal can reach it and everything it
/// started without touching Bubble, and it inherits none of Bubble's file descriptors.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    private var inputFD: Int32
    private let outputFD: Int32
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    init?(path: String, arguments: [String], environment: [String: String], directory: String? = nil) {
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&inputPipe) == 0 else { return nil }
        guard pipe(&outputPipe) == 0 else {
            inputPipe.forEach { close($0) }
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group; close every descriptor not set up above; default signal handling
        // (Bubble ignores SIGPIPE, and ignored signals would otherwise be inherited).
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(inputPipe[0])
        close(outputPipe[1])
        guard status == 0 else {
            close(inputPipe[1])
            close(outputPipe[0])
            return nil
        }
        self.pid = pid
        inputFD = inputPipe[1]
        outputFD = outputPipe[0]
    }

    deinit {
        readSource?.cancel()
        exitSource?.cancel()
        closeInput()
    }

    /// Delivers output chunks on `queue` until EOF, then calls `onEnd` once. Also reaps the
    /// process when it exits, so it never lingers as a zombie.
    func start(queue: DispatchQueue, onOutput: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
        let fd = outputFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        source.setEventHandler { [weak self] in
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                onOutput(Data(buffer[0 ..< count]))
            } else if count == 0 || errno != EINTR && errno != EAGAIN {
                self?.readSource?.cancel()
            }
        }
        source.setCancelHandler {
            close(fd)
            onEnd()
        }
        readSource = source
        source.resume()

        let pid = pid
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.exitSource?.cancel()
        }
        exitSource = exit
        exit.resume()
    }

    /// Writes to the child's stdin. Returns false if the child has gone away.
    @discardableResult
    func write(_ string: String) -> Bool {
        guard inputFD >= 0 else { return false }
        var bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { Darwin.write(inputFD, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// Sends `signal` to the child and everything in its process group.
    func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
    }

    /// Closes stdin (which ends both of Bubble's helpers) and makes sure the group goes away.
    func terminate() {
        closeInput()
        kill(-pid, SIGHUP)
        kill(-pid, SIGTERM)
        // Reap it even if this object is released before the exit event arrives.
        let pid = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func closeInput() {
        guard inputFD >= 0 else { return }
        close(inputFD)
        inputFD = -1
    }
}
