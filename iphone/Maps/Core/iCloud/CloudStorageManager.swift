enum VoidResult {
  case success
  case failure(Error)
}

typealias VoidResultCompletionHandler = (VoidResult) -> Void

enum CloudSynchronizationError: Error {
  case iCloudIsNotAvailable
  case containerNotFound
  case failedToSaveFile
  case failedToPrepareFile
  case failedToOpenFile
  case failedToUploadFile
}

let kKMLTypeIdentifier = "com.google.earth.kml"
let kFileExtensionKML = "kml" // only the *.kml is supported
let kDocumentsDirectoryName = "Documents"
let kTrashDirectoryName = ".Trash"
let kUDDidFinishInitialiCloudSynchronization = "kUDDidFinishInitialiCloudSynchronization"

@objc @objcMembers final class CloudStorageManger: NSObject {

  private let fileCoordinator = NSFileCoordinator()
  private let localDirectoryMonitor: LocalDirectoryMonitor
  private let cloudDirectoryMonitor: CloudDirectoryMonitor
  private let synchronizationStateManager: SynchronizationStateManager
  private let bookmarksManager = BookmarksManager.shared()
  private let backgroundQueue = DispatchQueue(label: "iCloud.app.organicmaps.backgroundQueue", qos: .background)
  private var isSynchronizationInProcess = false {
    didSet {
      LOG(.debug, "isSynchronizationInProcess: \(isSynchronizationInProcess)")
    }
  }
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
  private var isInitialSynchronizationFinished: Bool = true
  private var localDirectoryUrl: URL { localDirectoryMonitor.directory }

  // TODO: Sync properies using ubiqitousUD plist
//  {
//    get {
//      UserDefaults.standard.bool(forKey: kUDDidFinishInitialiCloudSynchronization)
//    }
//    set {
//      UserDefaults.standard.set(newValue, forKey: kUDDidFinishInitialiCloudSynchronization)
//    }
//  }
  private var needsToReloadBookmarksOnTheMap = false

  static let shared = CloudStorageManger()

  // MARK: - Initialization
  init(cloudDirectoryMonitor: CloudDirectoryMonitor = CloudDirectoryMonitor.default,
       localDirectoryMonitor: LocalDirectoryMonitor = LocalDirectoryMonitor.default,
       synchronizationStateManager: SynchronizationStateManager = DefaultSynchronizationStateManager()) {
    self.cloudDirectoryMonitor = cloudDirectoryMonitor
    self.localDirectoryMonitor = localDirectoryMonitor
    self.synchronizationStateManager = synchronizationStateManager
    super.init()
  }

  @objc func start() {
    subscribeToApplicationLifecycleNotifications()
    cloudDirectoryMonitor.delegate = self
    localDirectoryMonitor.delegate = self
  }
}

// MARK: - Private
private extension CloudStorageManger {
  func subscribeToApplicationLifecycleNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc func appWillEnterForeground() {
    cancelBackgroundTaskExtension()
    startSynchronization()
  }

  @objc func appDidEnterBackground() {
    extendBackgroundExecutionIfNeeded { [weak self] in
      self?.stopSynchronization()
      self?.cancelBackgroundTaskExtension()
    }
  }

  private func startSynchronization() {
    guard !cloudDirectoryMonitor.isStarted else { return }
    cloudDirectoryMonitor.start { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        do {
          try self.localDirectoryMonitor.start()
        } catch {
          // TODO: если локальный монитор не работает то выкл
          // TODO: handle error
          LOG(.debug, "LocalDirectoryMonitor start failed with error: \(error)")
          stopSynchronization()
        }
      case .failure(let error):
        // TODO: синк не должен включаться если клауд не включен и контейнер не доступен;
        // TODO: handle error
        LOG(.debug, "CloudDirectoryMonitor start failed with error: \(error)")
        stopSynchronization()
      }
    }
  }

  private func stopSynchronization() {
    localDirectoryMonitor.stop()
    cloudDirectoryMonitor.stop()
    synchronizationStateManager.resolveEvent(.resetState)
  }
}

// MARK: - iCloudStorageManger + LocalDirectoryMonitorDelegate
extension CloudStorageManger: LocalDirectoryMonitorDelegate {
  func didFinishGathering(contents: LocalContents) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didFinishGathering")
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringLocalContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: LocalContents) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didUpdate")
    let events = synchronizationStateManager.resolveEvent(.didUpdateLocalContents(contents))
    processEvents(events)
  }
}

// MARK: - iCloudStorageManger + CloudDirectoryMonitorDelegate
extension CloudStorageManger: CloudDirectoryMonitorDelegate {
  func didFinishGathering(contents: CloudContents) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didFinishGathering")
    let events = synchronizationStateManager.resolveEvent(.didFinishGatheringCloudContents(contents))
    processEvents(events)
  }

  func didUpdate(contents: CloudContents) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didUpdate")
    let events = synchronizationStateManager.resolveEvent(.didUpdateCloudContents(contents))
    processEvents(events)
  }
}

// MARK: - Handle Read/Write Events
private extension CloudStorageManger {
  func processEvents(_ events: [OutgoingEvent]) {
    events.forEach { [weak self] event in
      guard let self else { return }
      LOG(.debug, "Process event: \(event)")
      self.backgroundQueue.async {
        switch event {
        case .createLocalItem(let cloudMetadataItem): self.writeLocalItem(cloudMetadataItem, completion: self.resultCompletionHandler())
        case .updateLocalItem(let cloudMetadataItem): self.writeLocalItem(cloudMetadataItem, completion: self.resultCompletionHandler())
        case .removeLocalItem(let cloudMetadataItem): self.removeLocalItem(cloudMetadataItem, completion: self.resultCompletionHandler())
        case .startDownloading(let cloudMetadataItem): self.startDownloading(cloudMetadataItem, completion: self.resultCompletionHandler())
        case .createCloudItem(let localMetadataItem): self.writeCloudItem(localMetadataItem, completion: self.resultCompletionHandler())
        case .updateCloudItem(let localMetadataItem): self.writeCloudItem(localMetadataItem, completion: self.resultCompletionHandler())
        case .removeCloudItem(let localMetadataItem): self.removeCloudItem(localMetadataItem, completion: self.resultCompletionHandler())
        case .stopSynchronization(let synchronizationStopReason): self.stopSynchronization()
        case .resumeSynchronization:
          // TODO: Handle resume sync
          break
        case .didReceiveError(let error):
          // TODO: Handle Errors
          break
        }
      }
    }
    backgroundQueue.async {
      self.isSynchronizationInProcess = false
      self.cancelBackgroundTaskExtension()
    }
  }

  func resultCompletionHandler() -> VoidResultCompletionHandler {
    return { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        LOG(.error, "iCloudStorageManger - completionHandler with error: \(error)")
      case .success:
        LOG(.debug, "iCloudStorageManger - completionHandler with success.")
        self.reloadBookmarksOnTheMapIfNeeded()
      }
    }
  }

  func startDownloading(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    LOG(.debug, "Start downloading file: \(cloudMetadataItem.fileName)...")
    do {
      try FileManager.default.startDownloadingUbiquitousItem(at: cloudMetadataItem.fileUrl)
      completion(.success)
    } catch {
      completion(.failure(error))
    }
  }

  func writeLocalItem(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    LOG(.debug, "")
    var coordinationError: NSError?
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudMetadataItem.fileName)
    LOG(.debug, "File \(cloudMetadataItem.fileName) is downloaded to the local iCloud container. Start coordinating and writing file...")
    fileCoordinator.coordinate(readingItemAt: cloudMetadataItem.fileUrl, options: .withoutChanges, error: &coordinationError) { url in
      do {
        let cloudFileData = try Data(contentsOf: url)
        try cloudFileData.write(to: targetLocalFileUrl, options: .atomic, lastModificationDate: cloudMetadataItem.lastModificationDate)
        needsToReloadBookmarksOnTheMap = true
        LOG(.debug, "File \(cloudMetadataItem.fileName) is copied to local directory successfully.")
        completion(.success)
      } catch {
        completion(.failure(error))
      }
      return
    }
    if let coordinationError {
      completion(.failure(coordinationError))
    }
  }

  func removeLocalItem(_ cloudMetadataItem: CloudMetadataItem, completion: VoidResultCompletionHandler) {
    LOG(.debug, "")
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudMetadataItem.fileName)

    guard FileManager.default.fileExists(atPath: targetLocalFileUrl.path) else {
      LOG(.debug, "File \(cloudMetadataItem.fileName) is not exist in the local directory.")
      completion(.success)
      return
    }

    do {
      try FileManager.default.removeItem(at: targetLocalFileUrl) // TODO: trash?
      needsToReloadBookmarksOnTheMap = true
      LOG(.debug, "File \(cloudMetadataItem.fileName) is removed from the local directory successfully.")
      completion(.success)
    } catch {
      LOG(.error, "Failed to remove file \(cloudMetadataItem.fileName) from the local directory.")
      completion(.failure(error))
    }
  }

  func writeCloudItem(_ localMetadataItem: LocalMetadataItem, completion: @escaping VoidResultCompletionHandler) {
    LOG(.debug, "")
    cloudDirectoryMonitor.fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localMetadataItem.fileName)
        let fileData = localMetadataItem.fileData
        var coordinationError: NSError?

        LOG(.debug, "Start coordinating and writing file \(localMetadataItem.fileName)...")
        fileCoordinator.coordinate(writingItemAt: targetCloudFileUrl, options: [], error: &coordinationError) { url in
          do {
            try fileData.write(to: url, lastModificationDate: localMetadataItem.lastModificationDate)
            completion(.success)
          } catch {
            completion(.failure(error))
          }
          return
        }
        if let coordinationError {
          completion(.failure(coordinationError))
        }
      }
    }
  }

  func removeCloudItem(_ localMetadataItem: LocalMetadataItem, completion: @escaping VoidResultCompletionHandler) {
    cloudDirectoryMonitor.fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let cloudDirectoryUrl):
        LOG(.debug, "Start coordinating and removing file...")
        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localMetadataItem.fileName)
        var coordinationError: NSError?

        fileCoordinator.coordinate(writingItemAt: targetCloudFileUrl, options: [.forMoving], error: &coordinationError) { url in
          do {
//             TODO: move to trash by our own
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
//            let
//            let trashFileUrl = cloudDirectoryUrl.appendingPathComponent(kTrashDirectoryName, isDirectory: true).appendingPathComponent(localMetadataItem.fileName)
//            try FileManager.default.moveItem(at: url, to: trashFileUrl)
            completion(.success)
          } catch {
            completion(.failure(error))
          }
          return
        }
        if let coordinationError {
          completion(.failure(coordinationError))
        }
      }
    }
  }

  func trashCloudItem(_ cloudItem: CloudMetadataItem) throws {

  }

  // FIXME: Multiple calls of reload cause issue on the bookmarks screen
  func reloadBookmarksOnTheMapIfNeeded() {
    if needsToReloadBookmarksOnTheMap {
      LOG(.debug, "Reloading bookmarks on the map...")
      needsToReloadBookmarksOnTheMap = false
      DispatchQueue.main.async {
        self.bookmarksManager.loadBookmarks()
      }
    }
  }
}

// MARK: - Extend background time execution
private extension CloudStorageManger {
  // Extends background execution time to finish uploading.
  func extendBackgroundExecutionIfNeeded(expirationHandler: (() -> Void)? = nil) {
    guard isSynchronizationInProcess else { return }
    LOG(.debug, "Begin background task execution...")
    backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: nil) { [weak self] in
      guard let self else { return }
      expirationHandler?()
      self.cancelBackgroundTaskExtension()
    }
  }

  func cancelBackgroundTaskExtension() {
    guard backgroundTaskIdentifier != .invalid else { return }
    LOG(.debug, "Cancel background task execution.")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      UIApplication.shared.endBackgroundTask(self.backgroundTaskIdentifier)
      self.backgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    }
  }
}

// MARK: - FileManager + Local Directories
extension FileManager {
  var documentsDirectoryUrl: URL {
    urls(for: .documentDirectory, in: .userDomainMask).first!
  }

  var bookmarksDirectoryUrl: URL {
    documentsDirectoryUrl.appendingPathComponent("bookmarks", isDirectory: true)
  }
}

// MARK: - URL + ResourceValues
fileprivate extension URL {
  var resourceLastModificationDate: Date? {
    try? resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
  }

  mutating func setResourceModificationDate(_ date: Date) throws {
    var resource = try resourceValues(forKeys:[.contentModificationDateKey])
    resource.contentModificationDate = date
    try setResourceValues(resource)
  }
}

fileprivate extension Data {
  func write(to url: URL, options: Data.WritingOptions = .atomic, lastModificationDate: Date? = nil) throws {
    var url = url
    try write(to: url, options: options)
    if let lastModificationDate {
      try url.setResourceModificationDate(lastModificationDate)
    }
  }
}

fileprivate extension Date {
  func isEqualTo(_ otherDate: Date, accuracy: TimeInterval = 1.0) -> Bool {
    let timeDifference = abs(self.timeIntervalSince(otherDate))
    return timeDifference <= accuracy
  }
}
