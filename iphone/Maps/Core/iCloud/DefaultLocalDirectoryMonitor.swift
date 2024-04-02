protocol DirectoryMonitor {
  var isStarted: Bool { get }
  var isPaused: Bool { get }

  func start(completion: VoidResultCompletionHandler?)
  func stop()
  func pause()
  func resume()
}

protocol LocalDirectoryMonitor: DirectoryMonitor {
  var directory: URL { get }
  var delegate: LocalDirectoryMonitorDelegate? { get set }
}

protocol LocalDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: LocalContents)
  func didUpdate(contents: LocalContents)
  func didReceiveLocalMonitorError(_ error: Error)
}

private let kBookmarksDirectoryName = "bookmarks"
private let kKMLTypeIdentifier = "com.google.earth.kml" // only the .kml is supported

final class DefaultLocalDirectoryMonitor: LocalDirectoryMonitor {

  typealias Delegate = LocalDirectoryMonitorDelegate

  fileprivate enum State {
    case stopped
    case started(dirSource: DispatchSourceFileSystemObject)
    case debounce(dirSource: DispatchSourceFileSystemObject, timer: Timer)
  }

  static let `default` = DefaultLocalDirectoryMonitor(directory: FileManager.default.bookmarksDirectoryUrl,
                                               matching: kKMLTypeIdentifier,
                                               requestedResourceKeys: [.nameKey])

  private let typeIdentifier: String
  private let requestedResourceKeys: Set<URLResourceKey>
  private let actualResourceKeys: [URLResourceKey]
  private var source: DispatchSourceFileSystemObject?
  private var state: State = .stopped
  private(set) var contents = LocalContents()

  // MARK: - Public properties
  let directory: URL
  var isStarted: Bool {
    if case .stopped = state {
      LOG(.debug, "DefaultLocalDirectoryMonitor isStarted \(true)")
      return true
    }
    LOG(.debug, "DefaultLocalDirectoryMonitor isStarted \(false)")
    return false
  }
  private(set) var isPaused: Bool = true  { didSet { LOG(.debug, "DefaultLocalDirectoryMonitor isPaused \(isPaused)") } }
  weak var delegate: Delegate?

  init(directory: URL, matching typeIdentifier: String, requestedResourceKeys: Set<URLResourceKey>) {
    self.directory = directory
    self.typeIdentifier = typeIdentifier
    self.requestedResourceKeys = requestedResourceKeys
    self.actualResourceKeys = [URLResourceKey](requestedResourceKeys.union([.typeIdentifierKey]))
  }

  // MARK: - Public methods
  func start(completion: VoidResultCompletionHandler? = nil) {
    guard case .stopped = state else { return }

    if let source {
      source.resume()
      state = .started(dirSource: source)
      return
    }

    do {
      let directorySource = try DefaultLocalDirectoryMonitor.source(for: directory)
      directorySource.setEventHandler { [weak self] in
        self?.queueDidFire()
      }
      directorySource.resume()
      source = directorySource

      let nowTimer = Timer.scheduledTimer(withTimeInterval: .zero, repeats: false) { [weak self] _ in
        self?.debounceTimerDidFire()
      }

      state = .debounce(dirSource: directorySource, timer: nowTimer)
      completion?(.success)
    } catch {
      stop()
      completion?(.failure(error))
    }
  }

  func stop() {
    pause()
    state = .stopped
    contents.removeAll()
  }

  func pause() {
    source?.suspend()
    isPaused = true
  }

  func resume() {
    source?.resume()
    isPaused = false
  }

  // MARK: - Private
  private static func source(for directory: URL) throws -> DispatchSourceFileSystemObject {
    if !FileManager.default.fileExists(atPath: directory.path) {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw error
      }
    }
    let directoryFileDescrtiptor = open(directory.path, O_EVTONLY)
    guard directoryFileDescrtiptor >= 0 else {
      let errorCode = errno
      throw NSError(domain: POSIXError.errorDomain, code: Int(errorCode), userInfo: nil)
    }
    return DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFileDescrtiptor, eventMask: [.write], queue: DispatchQueue.main)
  }

  private func queueDidFire() {
    switch state {
    case .started(let directorySource):
      let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
        self?.debounceTimerDidFire()
      }
      state = .debounce(dirSource: directorySource, timer: timer)
    case .debounce(_, let timer):
      timer.fireDate = Date(timeIntervalSinceNow: 0.2)
      // Stay in the `.debounce` state.
    case .stopped:
      // This can happen if the read source fired and enqueued a block on the
      // main queue but, before the main queue got to service that block, someone
      // called `stop()`.  The correct response is to just do nothing.
      break
    }
  }

  private static func contents(of directory: URL, matching typeIdentifier: String, including: [URLResourceKey]) -> Set<URL> {
    guard let rawContents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: including, options: [.skipsHiddenFiles]) else {
      return []
    }
    let filteredContents = rawContents.filter { url in
      guard let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]), let urlType = type.typeIdentifier else {
        return false
      }
      return urlType == typeIdentifier
    }
    return Set(filteredContents)
  }

  private func debounceTimerDidFire() {
    guard case .debounce(let dirSource, let timer) = state else { fatalError("LocalDirectoryMonitor is in invalid state: \(self.state)") }
    timer.invalidate()
    state = .started(dirSource: dirSource)

    let newContents = DefaultLocalDirectoryMonitor.contents(of: directory, matching: typeIdentifier, including: actualResourceKeys)
    let newContentMetadataItems = LocalContents(newContents.compactMap { url in
      do {
        let metadataItem = try LocalMetadataItem(fileUrl: url)
        return metadataItem
      } catch {
        delegate?.didReceiveLocalMonitorError(error)
        return nil
      }
    })

    // When the contentMetadataItems is empty, it means that we are in the initial state.
    if contents.isEmpty {
      delegate?.didFinishGathering(contents: newContentMetadataItems)
    } else {
      delegate?.didUpdate(contents: newContentMetadataItems)
    }
    contents = newContentMetadataItems
  }
}

fileprivate extension DefaultLocalDirectoryMonitor.State {
  var isRunning: Bool {
    switch self {
    case .stopped: return false
    case .started: return true
    case .debounce: return true
    }
  }
}

// MARK: - FileManager + Local Directories
private extension FileManager {
  var bookmarksDirectoryUrl: URL {
    urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(kBookmarksDirectoryName, isDirectory: true)
  }
}
