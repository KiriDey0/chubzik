import AppKit
import Foundation

final class SystemMedia {
    var changed: ((MediaItem?) -> Void)?
    var healthChanged: ((String) -> Void)?
    private var reader: Process?
    private var pipe: Pipe?
    private var decoder = NowPlayingDecoder()
    private var buffer = Data()
    private var retry: DispatchWorkItem?
    private var retryCount = 0
    private var startedAt: TimeInterval?
    private var enabled = false
    private let maxLine = 10 * 1024 * 1024

    private var adapter: [String]? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return [script.path, framework.path]
    }

    func start() {
        enabled = true
        guard reader == nil else { return }
        guard let adapter else {
            healthChanged?("Системный адаптер отсутствует")
            return
        }
        retry?.cancel()
        retry = nil
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = adapter + ["stream", "--micros"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        buffer.removeAll()
        decoder = NowPlayingDecoder()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let process, self.reader === process else { return }
                self.consume(data)
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, self.reader === process else { return }
                self.finish()
            }
        }
        reader = process
        pipe = output
        do {
            try process.run()
            startedAt = ProcessInfo.processInfo.systemUptime
            healthChanged?("Системный Now Playing подключён")
        } catch {
            finish()
        }
    }

    func stop() {
        enabled = false
        retryCount = 0
        retry?.cancel()
        retry = nil
        startedAt = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if reader?.isRunning == true { reader?.terminate() }
        reader = nil
        pipe = nil
        buffer.removeAll()
    }

    func command(_ action: String, position: Double? = nil) {
        guard let adapter else { return }
        let arguments: [String]
        if action == "seek", let position, position.isFinite, position >= 0, position < 7 * 24 * 3600 {
            arguments = ["seek", String(Int64(position * 1_000_000))]
        } else {
            let codes = ["play": "0", "pause": "1", "toggle": "2", "next": "4", "previous": "5"]
            guard let code = codes[action] else { return }
            arguments = ["send", code]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = adapter + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(of: 10) {
            if end > start, end - start < maxLine {
                do {
                    let item = try decoder.ingest(Data(buffer[start..<end]))
                    changed?(item)
                } catch {
                    healthChanged?("Системные данные плеера повреждены")
                }
            }
            start = end + 1
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        if buffer.count > maxLine { buffer.removeAll() }
    }

    private func finish() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        reader = nil
        pipe = nil
        changed?(nil)
        healthChanged?("Системный Now Playing недоступен")
        guard enabled else { return }
        if let startedAt, ProcessInfo.processInfo.systemUptime - startedAt >= 60 { retryCount = 0 }
        startedAt = nil
        retryCount = min(8, retryCount + 1)
        let item = DispatchWorkItem { [weak self] in self?.start() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount * 8), execute: item)
    }
}
