enum VoidResult {
  case success
  case failure(Error)
}

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

@objc @objcMembers final class iCloudStorageManger: NSObject {

  private let fileCoordinator = NSFileCoordinator()
  private let localDirectoryMonitor: LocalDirectoryMonitor
  private let cloudDirectoryMonitor: CloudDirectoryMonitor
  private var localDirectoryMetadata: Set<LocalMetadataItem> = []
  private var cloudDirectoryMetadata: Set<CloudMetadataItem> = []
  private var localDirectoryDidFinishInitialGathering = false
  private var cloudDirectoryDidFinishInitialGathering = false
  private let bookmarksManager = BookmarksManager.shared()
  private let backgroundQueue = DispatchQueue(label: "iCloud.app.organicmaps.backgroundQueue", qos: .background/*, attributes: .concurrent*/)
  private var isSynchronizationInProcess = false
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
  private let localDirectoryUrl = FileManager.default.bookmarksDirectoryUrl
  private var isInitialSynchronizationFinished: Bool = true

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

  static let shared = iCloudStorageManger()

  // MARK: - Initialization
  override init() {
    self.cloudDirectoryMonitor = CloudDirectoryMonitor.shared
    self.localDirectoryMonitor = LocalDirectoryMonitor(directory: FileManager.default.bookmarksDirectoryUrl,
                                                       matching: kKMLTypeIdentifier,
                                                       requestedResourceKeys: [.nameKey])
    super.init()
  }

  @objc func start() {
    subscribeToApplicationLifecycleNotifications()
    cloudDirectoryMonitor.delegate = self
    localDirectoryMonitor.delegate = self
  }
}

// MARK: - Private
private extension iCloudStorageManger {
  func subscribeToApplicationLifecycleNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc func appWillEnterForeground() {
    cancelBackgroundTask()
    startSynchronization()
  }

  @objc func appDidEnterBackground() {
    beginBackgroundTask { [weak self] in
      self?.stopSynchronization()
      self?.cancelBackgroundTask()
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
    localDirectoryMetadata.removeAll()
    cloudDirectoryMetadata.removeAll()
    localDirectoryDidFinishInitialGathering = false
    cloudDirectoryDidFinishInitialGathering = false
  }
}

// MARK: - iCloudStorageManger + LocalDirectoryMonitorDelegate
extension iCloudStorageManger: LocalDirectoryMonitorDelegate {
  func didFinishGathering(directoryMonitor: AnyObject, content: Set<LocalMetadataItem>) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didFinishGathering")
    content.forEach({ item in
      LOG(.debug, "name: \(item.fileName), lastModified: \(item.lastModificationDate)")
    })
    // TODO: add async on BG queue
    backgroundQueue.async { [self] in
      localDirectoryMetadata = content
      localDirectoryDidFinishInitialGathering = true
      handleDidFinishGathering(localContent: content, cloudContent: cloudDirectoryMetadata) { [weak self] result in
        guard let self else { return }
        switch result {
        case .failure(let error):
          LOG(.error, "LocalDirectoryMonitorDelegate - didFinishGathering with error: \(error.localizedDescription)")
          dump(error)
        case .success:
          LOG(.debug, "LocalDirectoryMonitorDelegate - didFinishGathering with success")
          break
        }
        self.isSynchronizationInProcess = false
        self.cancelBackgroundTask()
        self.reloadBookmarksOnTheMapIfNeeded()
      }
    }
  }

  func didUpdate(directoryMonitor: AnyObject, content: Set<LocalMetadataItem>, added: Set<LocalMetadataItem>, updated: Set<LocalMetadataItem>, removed: Set<LocalMetadataItem>) {
    LOG(.debug, "LocalDirectoryMonitorDelegate - didUpdate")
    LOG(.debug, "added:")
    added.forEach({ dump($0) })
    LOG(.debug, "updated:")
    updated.forEach({ dump($0) })
    LOG(.debug, "removed:")
    removed.forEach({ dump($0) })

    // TODO: add async on BG queue
    localDirectoryMetadata = content
    localDirectoryDidUpdate(added: added, updated: updated, removed: removed) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        LOG(.error, "LocalDirectoryMonitorDelegate - didUpdate with error: \(error.localizedDescription)")
        dump(error)
      case .success:
        LOG(.debug, "LocalDirectoryMonitorDelegate - didUpdate with sucess.")
        break
      }
      self.isSynchronizationInProcess = false
      self.cancelBackgroundTask()
      self.reloadBookmarksOnTheMapIfNeeded()
    }
  }
}

// MARK: - iCloudStorageManger + CloudDirectoryMonitorDelegate
extension iCloudStorageManger: CloudDirectoryMonitorDelegate {
  func didFinishGathering(directoryMonitor: AnyObject, content: Set<CloudMetadataItem>) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didFinishGathering")
    content.forEach({ dump($0) })
    
    cloudDirectoryMetadata = content
    cloudDirectoryDidFinishInitialGathering = true
    handleDidFinishGathering(localContent: localDirectoryMetadata, cloudContent: content) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        LOG(.error, "CloudDirectoryMonitorDelegate - didFinishGathering with error: \(error.localizedDescription)")
        LOG(.error, "CloudDirectoryMonitorDelegate - didFinishGathering with error: \(error)")
        // TODO: handle error
      case .success:
        LOG(.debug, "CloudDirectoryMonitorDelegate - didFinishGathering with success.")
        // TODO: Handle success
        break
      }
      self.cancelBackgroundTask()
      self.isSynchronizationInProcess = false
      self.cloudDirectoryMonitor.resume()
      self.reloadBookmarksOnTheMapIfNeeded()
    }
  }

  func didUpdate(directoryMonitor: AnyObject, content: Set<CloudMetadataItem>, added: Set<CloudMetadataItem>, updated: Set<CloudMetadataItem>, removed: Set<CloudMetadataItem>) {
    LOG(.debug, "CloudDirectoryMonitorDelegate - didUpdate")
    LOG(.debug, "added:")
    added.forEach({ dump($0) })
    LOG(.debug, "updated:")
    updated.forEach({ dump($0) })
    LOG(.debug, "removed:")
    removed.forEach({ dump($0) })
    
    cloudDirectoryMetadata = content
    cloudDirectoryDidUpdate(added: added, updated: updated, removed: removed) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        LOG(.error, "CloudDirectoryMonitorDelegate - didFinishGathering with error: \(error.localizedDescription)")
        LOG(.error, "CloudDirectoryMonitorDelegate - didFinishGathering with error: \(error)")
        // TODO: handle error
      case .success:
        LOG(.debug, "CloudDirectoryMonitorDelegate - didFinishGathering with success.")
        // TODO: Handle success
      }
      self.cancelBackgroundTask()
      self.isSynchronizationInProcess = false
      self.reloadBookmarksOnTheMapIfNeeded()
    }
  }
}

// MARK: - Handle Updates
private extension iCloudStorageManger {
  func handleDidFinishGathering(localContent: Set<LocalMetadataItem>, cloudContent: Set<CloudMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    guard cloudDirectoryDidFinishInitialGathering, localDirectoryDidFinishInitialGathering else { return }

    // When the app was installed on the new device and nave no bookmarks but one empty group is created by default.
    // TODO: make some method in the bookmarks manager to check if there are no bookmarks at all.
    let localContentIsFullyEmpty = bookmarksManager.sortedUserCategories().first(where: { bookmarksManager.category(withId: $0.categoryId).bookmarksCount != 0}) == nil

    // Pause monitoring the cloud directory before the initial synchronization is finished (because there will be a lot of updates).
    cloudDirectoryMonitor.pause()
    isSynchronizationInProcess = true

    switch (localContentIsFullyEmpty, cloudContent.isEmpty) {
    case (true, true):
      completion(.success)
    case (true, false):
      startRestoringAllFilefFromTheCloud(cloudContent: cloudContent, completion: completion)
    case (false, true):
      startUploadingAllFilesToTheCloud(localContent: localContent, completion: completion)
    case (false, false):
      startRegularSynchronization(localContent: localContent, cloudContent: cloudContent, completion: completion)
    }
  }

  func startUploadingAllFilesToTheCloud(localContent: Set<LocalMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    LOG(.debug, "Start uploading of all local files to iCloud...")
    let dispatchGroup = DispatchGroup()
    var processingError: Error?
    // TODO: Обрабатывать ли ошибки для каждого файла отдельно или все скопом (массив ошибок)?
    localContent.forEach { [weak self] localFile in
      guard let self else { return }
      dispatchGroup.enter()
      backgroundQueue.async(group: dispatchGroup) {
        self.localFileDidAdded(localFile) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }
    dispatchGroup.notify(queue: .main) {
      // TODO: некрасиво ошибки обрабатываются
      if let processingError {
        LOG(.error, "Uploading of all local files to iCloud failed with error: \(processingError.localizedDescription)")
        completion(.failure(processingError))
        return
      }
      LOG(.debug, "Uploading of all local files to iCloud finished successfully.")
      completion(.success)
    }
  }

  func startRestoringAllFilefFromTheCloud(cloudContent: Set<CloudMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    LOG(.debug, "Start restoring of all files from iCloud...")
    let dispatchGroup = DispatchGroup()
    var processingError: Error?
    cloudContent.forEach({ [weak self] cloudFile in
      guard let self else { return }
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.cloudFileDidAdded(cloudFile) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
      dispatchGroup.notify(queue: .main) {
        if let processingError {
          LOG(.error, "Restoring of all files from iCloud failed with error: \(processingError.localizedDescription)")
          completion(.failure(processingError))
          return
        }
        LOG(.debug, "Restoring of all files from iCloud finished successfully.")
        completion(.success)
      }
    })
  }

  func startRegularSynchronization(localContent: Set<LocalMetadataItem>, cloudContent: Set<CloudMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    LOG(.debug, "Start regular synchronization...")
    let dispatchGroup = DispatchGroup()
    var processingError: Error?

    // TODO: should we remove files from the local directory if they are not in the cloud? This files should be removed here.
    let itemsToUpdateInCloud = cloudContent.reduce(into: Set<LocalMetadataItem>()) { result, cloudFile in
      guard let localFile = localContent.itemWithName(cloudFile.fileName) as? LocalMetadataItem,
            cloudFile.lastModificationDate < localFile.lastModificationDate else { return }
      result.insert(localFile)
    }
    let itemsToUpdateInLocal = localContent.reduce(into: Set<CloudMetadataItem>()) { result, localFile in
      guard let cloudFile = cloudContent.itemWithName(localFile.fileName) as? CloudMetadataItem,
            cloudFile.lastModificationDate > localFile.lastModificationDate else { return }
      result.insert(cloudFile)
    }
    let itemsToRemoveFromLocal = localContent.filter { cloudContent.map { $0.fileName }.contains($0.fileName) == false }

    itemsToUpdateInCloud.forEach { [weak self] fileToUpdate in
      guard let self else { return }
      backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.localFileDidUpdated(fileToUpdate) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }

    itemsToUpdateInLocal.forEach { [weak self] fileToUpdate in
      guard let self else { return }
      backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.cloudFileDidUpdated(fileToUpdate) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }

    itemsToRemoveFromLocal.forEach { [weak self] fileToRemove in
      guard let self else { return }
      dispatchGroup.enter()
      backgroundQueue.async(group: dispatchGroup) {
        do {
          try FileManager.default.trashItem(at: fileToRemove.fileUrl, resultingItemURL: nil)
        } catch {
          processingError = error
        }
        dispatchGroup.leave()
      }
    }

    dispatchGroup.notify(queue: .main) {
      if let processingError {
        LOG(.error, "Regular synchronization failed with error: \(processingError.localizedDescription)")
        completion(.failure(processingError))
        return
      }
      LOG(.debug, "Regular synchronization with iCloud finished successfully.")
      completion(.success)
    }
  }

  func localDirectoryDidUpdate(added: Set<LocalMetadataItem>, updated: Set<LocalMetadataItem>, removed: Set<LocalMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    isSynchronizationInProcess = true
    let dispatchGroup = DispatchGroup()
    var processingError: Error?
    added.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.localFileDidAdded(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }
    removed.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.localFileDidRemoved(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }
    updated.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.localFileDidUpdated(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }

    // TODO: fix error handling - it's not good to return only the last error
    DispatchQueue.main.async {
      self.isSynchronizationInProcess = false
      if let processingError {
        completion(.failure(processingError))
      } else {
        completion(.success)
      }
    }
  }

  func cloudDirectoryDidUpdate(added: Set<CloudMetadataItem>, updated: Set<CloudMetadataItem>, removed: Set<CloudMetadataItem>, completion: @escaping (VoidResult) -> Void) {
    isSynchronizationInProcess = true

    let dispatchGroup = DispatchGroup()
    var processingError: Error?
    added.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.cloudFileDidAdded(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }
    removed.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.cloudFileDidRemoved(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }
    updated.forEach { file in
      self.backgroundQueue.async(group: dispatchGroup) {
        dispatchGroup.enter()
        self.cloudFileDidUpdated(file) { error in
          processingError = error
          dispatchGroup.leave()
        }
      }
    }

    // TODO: fix error handling - it's not good to return only the last error
    DispatchQueue.main.async {
      self.isSynchronizationInProcess = false
      if let processingError {
        completion(.failure(processingError))
      } else {
        completion(.success)
      }
    }
  }

  // MARK: - Handle local file changes
  func localFileDidAdded(_ localFile: LocalMetadataItem, completion: @escaping (Error?) -> Void) {
    LOG(.debug, "")
    cloudDirectoryMonitor.fetchUbiquityDocumentsDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(error)
      case .success(let cloudDirectoryUrl):
        if fileExistsAndUpToDate(localFile, in: cloudDirectoryMetadata) {
          LOG(.debug, "File \(localFile.fileName) is up to date")
          completion(nil)
          return
        }

        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localFile.fileName)
        let fileData = localFile.fileData
        var coordinationError: NSError?

        LOG(.debug, "Start coordinating and writing file \(localFile.fileName)...")
        fileCoordinator.coordinate(writingItemAt: targetCloudFileUrl, options: [], error: &coordinationError) { url in
          do {
            try fileData.write(to: url, lastModificationDate: localFile.lastModificationDate)
            completion(nil)
          } catch {
            completion(error)
          }
          return
        }
        if let coordinationError {
          completion(coordinationError)
        }
      }
    }
  }

  func localFileDidUpdated(_ localFile: LocalMetadataItem, completion: @escaping (Error?) -> Void) {
    LOG(.debug, "")
    cloudDirectoryMonitor.fetchUbiquityDocumentsDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(error)
      case .success(let cloudDirectoryUrl):
        if fileExistsAndUpToDate(localFile, in: cloudDirectoryMetadata) {
          LOG(.debug, "File \(localFile.fileName) is up to date")
          completion(nil)
          return
        }

        let targetCloudFileUrl = cloudDirectoryUrl.appendingPathComponent(localFile.fileName)
        let fileData = localFile.fileData
        var coordinationError: NSError?

        LOG(.debug, "Start coordinating and writing file \(localFile.fileName)...")
        fileCoordinator.coordinate(writingItemAt: targetCloudFileUrl, options: [], error: &coordinationError) { url in
          do {
            try fileData.write(to: url, lastModificationDate: localFile.lastModificationDate)
            completion(nil)
          } catch {
            completion(error)
          }
          return
        }
        if let coordinationError {
          completion(coordinationError)
        }
      }
    }
  }

  func localFileDidRemoved(_ localFile: LocalMetadataItem, completion: @escaping (Error?) -> Void) {
    cloudDirectoryMonitor.fetchUbiquityDocumentsDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(error)
      case .success(let cloudDirectoryUrl):

        guard let cloudFile = cloudDirectoryMetadata.itemWithName(localFile.fileName) else {
          LOG(.debug, "File not found in cloud")
          completion(nil)
          return
        }

        LOG(.debug, "Start coordinating and removing file...")
        var coordinationError: NSError?
        fileCoordinator.coordinate(writingItemAt: cloudFile.fileUrl, options: [.forDeleting], error: &coordinationError) { url in
          do {
//            try FileManager.default.removeItem(at: url)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            completion(nil)
          } catch {
            completion(error)
          }
          return
        }
        if let coordinationError {
          completion(coordinationError)
        }
      }
    }
  }

  func fileExistsAndUpToDate<T: MetadataItem>(_ file: any MetadataItem, in content: Set<T>) -> Bool {
    guard let fileInContainer = content.itemWithName(file.fileName) else { return false }
    return file.lastModificationDate.isEqualTo(fileInContainer.lastModificationDate)
  }

  // MARK: - Handle cloud file changes
  func cloudFileDidAdded(_ cloudFile: CloudMetadataItem, completion: @escaping (Error?) -> Void) {
    LOG(.debug, "")
    if fileExistsAndUpToDate(cloudFile, in: localDirectoryMetadata) {
      LOG(.debug, "File \(cloudFile.fileName) is up to date")
      completion(nil)
      return
    }

    guard cloudFile.isDownloaded else {
      LOG(.debug, "File \(cloudFile.fileName) is not downloaded to the local iCloud container.")
      do {
        try FileManager.default.startDownloadingUbiquitousItem(at: cloudFile.fileUrl)
        LOG(.debug, "Start DownloadingUbiquitousItem: \(cloudFile.fileName)...")
        completion(nil)
      } catch {
        completion(error)
      }
      return
    }

    var coordinationError: NSError?
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudFile.fileName)
    LOG(.debug, "File \(cloudFile.fileName) is downloaded to the local iCloud container. Start coordinating and writing file...")
    fileCoordinator.coordinate(readingItemAt: cloudFile.fileUrl, options: .forUploading, error: &coordinationError) { url in
      do {
        let cloudFileData = try Data(contentsOf: url)
        try cloudFileData.write(to: targetLocalFileUrl, options: .atomic, lastModificationDate: cloudFile.lastModificationDate)
        needsToReloadBookmarksOnTheMap = true
        LOG(.debug, "File \(cloudFile.fileName) is copied to local directory successfully.")
        completion(nil)
      } catch {
        completion(error)
      }
      return
    }
    if let coordinationError {
      completion(coordinationError)
    }
  }

  func cloudFileDidUpdated(_ cloudFile: CloudMetadataItem, completion: @escaping (Error?) -> Void) {
    LOG(.debug, "")

    if cloudFile.isInTrash {
      cloudFileDidRemoved(cloudFile, completion: completion)
      return
    }

    if fileExistsAndUpToDate(cloudFile, in: localDirectoryMetadata) {
      LOG(.debug, "File \(cloudFile.fileName) is up to date. Skip updating.")
      completion(nil)
      return
    }

    guard cloudFile.isDownloaded else {
      LOG(.debug, "File \(cloudFile.fileName) is not downloaded to the local iCloud container.")
      do {
        try FileManager.default.startDownloadingUbiquitousItem(at: cloudFile.fileUrl)
        LOG(.debug, "startDownloadingUbiquitousItem from iCloud: \(cloudFile.fileName)")
        completion(nil)
      } catch {
        completion(error)
      }
      return
    }

    LOG(.debug, "File \(cloudFile.fileName) is downloaded to the local iCloud container. Start coordinating and writing file...")
    var coordinationError: NSError?
    let targetLocalFileUrl = localDirectoryUrl.appendingPathComponent(cloudFile.fileName)

    fileCoordinator.coordinate(readingItemAt: cloudFile.fileUrl, options: .forUploading, error: &coordinationError) { url in
      // TODO: refactor localFile - earlier i already checked if it exists. Needs to unwrap it only once
      guard let localFile = localDirectoryMetadata.itemWithName(cloudFile.fileName) else {
        LOG(.error, "Local file is not found. It should be added to the local directory first.")
        do {
          let cloudFileData = try Data(contentsOf: url)
          try cloudFileData.write(to: targetLocalFileUrl, lastModificationDate: cloudFile.lastModificationDate)
          needsToReloadBookmarksOnTheMap = true
          LOG(.debug, "File \(cloudFile.fileName) is copied to local directory successfully.")
          completion(nil)
        } catch {
          completion(error)
        }
        return
      }
      LOG(.debug, "File \(cloudFile.fileName) is already in the local directory. Check the last modification date...")
      if localFile.lastModificationDate < cloudFile.lastModificationDate {
        LOG(.debug, "Local file is older than the cloud file. Start copying...")
        do {
          let cloudFileData = try Data(contentsOf: url)
          try cloudFileData.write(to: targetLocalFileUrl, lastModificationDate: cloudFile.lastModificationDate)
          needsToReloadBookmarksOnTheMap = true
          LOG(.debug, "File \(cloudFile.fileName) is copied to local directory successfully.")
          completion(nil)
        } catch {
          completion(error)
        }
      } else {
        // TODO: Handle merge conflict when the cloud version is updated, but still older than the local
        LOG(.debug, "Merge conflict. Local file \(cloudFile.fileName) is newer than the cloud file. File should be duplicated.")
        completion(nil)
      }
    }
    if let coordinationError {
      completion(coordinationError)
    }
  }

  func cloudFileDidRemoved(_ cloudFile: CloudMetadataItem, completion: @escaping (Error?) -> Void) {
    LOG(.debug, "")

    guard let localFile = localDirectoryMetadata.itemWithName(cloudFile.fileName) as? LocalMetadataItem else {
      LOG(.debug, "File \(cloudFile.fileName) is not exist in the local directory content set.")
      completion(nil)
      return
    }

    guard FileManager.default.fileExists(atPath: localFile.fileUrl.path) else {
      LOG(.debug, "File \(cloudFile.fileName) is not exist in the local directory.")
      completion(nil)
      return
    }

    // Merge Conflict: Local file version is newer than the deleted cloud version. File will be duplicated.
    guard localFile.lastModificationDate > cloudFile.lastModificationDate else {
      LOG(.error, "Merge Conflict: Local file \(localFile.fileName) version is newer than the deleted cloud version.")
      localFileDidAdded(localFile, completion: completion)
      return
    }

    do {
      try FileManager.default.removeItem(at: localFile.fileUrl)
      needsToReloadBookmarksOnTheMap = true
      LOG(.debug, "File \(cloudFile.fileName) is removed from the local directory successfully.")
      completion(nil)
    } catch {
      LOG(.error, "Failed to remove file \(cloudFile.fileName) from the local directory.")
      completion(error)
    }
  }

  func reloadBookmarksOnTheMapIfNeeded() {
    if needsToReloadBookmarksOnTheMap {
      LOG(.debug, "Reloading bookmarks on the map...")
      needsToReloadBookmarksOnTheMap = false
      bookmarksManager.loadBookmarks()
    }
  }
}

// MARK: - Extend background time execution
private extension iCloudStorageManger {
  // Extends background execution time to finish uploading.
  func beginBackgroundTask(expirationHandler: (() -> Void)? = nil) {
    guard isSynchronizationInProcess else { return }
    LOG(.debug, "Begin background task execution...")
    backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: nil) { [weak self] in
      guard let self else { return }
      expirationHandler?()
      self.cancelBackgroundTask()
    }
  }

  func cancelBackgroundTask() {
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
fileprivate extension FileManager {
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
