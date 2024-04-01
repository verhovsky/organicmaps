protocol CloudDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: CloudContents)
  func didUpdate(contents: CloudContents)
  func didReceiveCloudMonitorError(_ error: Error)
}

private let kTrashDirectoryName = ".Trash"
private let kUDCloudIdentityKey = "com.apple.organicmaps.UbiquityIdentityToken"

final class CloudDirectoryMonitor: NSObject {

  private static let sharedContainerIdentifier: String = {
    var identifier = "iCloud.app.organicmaps"
    #if DEBUG
    identifier.append(".debug")
    #endif
    return identifier
  }()

  static let `default` = CloudDirectoryMonitor(cloudContainerIdentifier: CloudDirectoryMonitor.sharedContainerIdentifier)

  private let metadataQuery = NSMetadataQuery()
  private var containerIdentifier: String
  private var ubiquitousDocumentsDirectory: URL?

  weak var delegate: CloudDirectoryMonitorDelegate?

  init(cloudContainerIdentifier: String = CloudDirectoryMonitor.sharedContainerIdentifier) {
    self.containerIdentifier = cloudContainerIdentifier
    super.init()

    setupMetadataQuery()
    subscribeToCloudAvailabilityNotifications()
    fetchUbiquityDocumentsDirectoryUrl()
  }

  // MARK: - Public
  var isStarted: Bool { return metadataQuery.isStarted }

  func start(completion: VoidResultCompletionHandler? = nil) {
    guard cloudIsAvailable() else {
      completion?(.failure(SynchronizationError.iCloudIsNotAvailable))
      return
    }
    fetchUbiquityDocumentsDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion?(.failure(error))
      case .success:
        self.startQuery()
        completion?(.success)
      }
    }
  }

  func stop() {
    stopQuery()
  }

  func resume() {
    metadataQuery.enableUpdates()
  }

  func pause() {
    metadataQuery.disableUpdates()
  }

  func fetchUbiquityDocumentsDirectoryUrl(completion: ((Result<URL, SynchronizationError>) -> Void)? = nil) {
    if let ubiquitousDocumentsDirectory {
      completion?(.success(ubiquitousDocumentsDirectory))
      return
    }
    DispatchQueue.global().async {
      guard let containerUrl = FileManager.default.url(forUbiquityContainerIdentifier: self.containerIdentifier) else {
        LOG(.error, "Failed to retrieve container's URL for:\(self.containerIdentifier)")
        completion?(.failure(.containerNotFound))
        return
      }
      let documentsContainerUrl = containerUrl.appendingPathComponent(kDocumentsDirectoryName)
      self.ubiquitousDocumentsDirectory = documentsContainerUrl
      completion?(.success(documentsContainerUrl))
    }
  }
}

// MARK: - Private
private extension CloudDirectoryMonitor {
  func cloudIsAvailable() -> Bool {
    let cloudToken = FileManager.default.ubiquityIdentityToken
    guard let cloudToken else {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is not available. Cloud token is nil.")
      return false
    }
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: cloudToken, requiringSecureCoding: true)
      UserDefaults.standard.set(data, forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is available.")
      return true
    } catch {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.error, "Failed to archive cloud token: \(error)")
      return false
    }
  }

  func subscribeToCloudAvailabilityNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(cloudAvailabilityChanged(_:)), name: .NSUbiquityIdentityDidChange, object: nil)
  }

  // FIXME: - Actually this notification was never called. If user disable the iCloud for the curren app during the active state the app will be relaunched. Needs to investigate additional cases when this notification can be sent.
  @objc func cloudAvailabilityChanged(_ notification: Notification) {
    LOG(.debug, "Cloud availability changed to : \(cloudIsAvailable())")
    cloudIsAvailable() ? startQuery() : stopQuery()
  }

  // MARK: - MetadataQuery
  private func setupMetadataQuery() {
    metadataQuery.notificationBatchingInterval = 1
    metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    metadataQuery.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(kFileExtensionKML)")
    metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

    NotificationCenter.default.addObserver(self, selector: #selector(queryDidFinishGathering(_:)), name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate(_:)), name: NSNotification.Name.NSMetadataQueryDidUpdate, object: nil)
  }

  func startQuery() {
    LOG(.info, "Start quering metadata.")
    guard !metadataQuery.isStarted else { return }
    metadataQuery.start()
  }

  func stopQuery() {
    LOG(.info, "Stop quering metadata.")
    metadataQuery.stop()
  }

  @objc func queryDidFinishGathering(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery, let metadataItems = metadataQuery.results as? [NSMetadataItem] else { return }
    pause()
    let newContent = getContentsOnDidFinishGathering(metadataItems)
    delegate?.didFinishGathering(contents: newContent)
    resume()
  }

  @objc func queryDidUpdate(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery, let metadataItems = metadataQuery.results as? [NSMetadataItem] else { return }
    pause()
    let newContent = getContentsOnDidUpdate(metadataItems, userInfo: notification.userInfo)
    delegate?.didUpdate(contents: newContent)
    resume()
  }

  // There are no ways to retrieve the content of iCloud's .Trash directory on macOS.
  // When we get a new notification and retrieve the metadata from the object the actual list of items in iOS contains both current and deleted files (which is in .Trash/ directory now) but on macOS we only have absence of the file. So there are no way to get list of deleted items on macOS on didFinishGathering state.
  // Due to didUpdate state we can get the list of deleted items on macOS from the userInfo property but cannot get their new url.
  private func getContentsOnDidFinishGathering(_ metadataItems: [NSMetadataItem]) -> CloudContents {
    do {
      var removedItems = try getRemovedItemsFromTrash()
      let removedCloudMetadataItems = CloudContents(removedItems.compactMap { url in
        do {
          var item = try CloudMetadataItem(fileUrl: url)
          item.isRemoved = true
          return item
        } catch {
          delegate?.didReceiveCloudMonitorError(error)
          return nil
        }
      })

      // Get regular (non trashed) cloud content
      let cloudMetadataItems = CloudContents(metadataItems.compactMap { item in
        do {
          let cloudMetadataItem = try CloudMetadataItem(metadataItem: item)
          return cloudMetadataItem
        } catch {
          delegate?.didReceiveCloudMonitorError(error)
          return nil
        }
      })
      let mergedMetadataItems = cloudMetadataItems.merging(removedCloudMetadataItems) { _, new in new }
      return mergedMetadataItems
    } catch {
      delegate?.didReceiveCloudMonitorError(error)
      return [:]
    }
  }

  private func getContentsOnDidUpdate(_ metadataItems: [NSMetadataItem], userInfo: [AnyHashable: Any]?) -> CloudContents {
    let removedCloudMetadataItems = getRemovedItemsFromUserInfo(userInfo)
    let cloudMetadataItems = CloudContents(metadataItems.compactMap { item in
      do {
        let cloudMetadataItem = try CloudMetadataItem(metadataItem: item)
        return cloudMetadataItem
      } catch {
        delegate?.didReceiveCloudMonitorError(error)
        return nil
      }
    })

    let mergedMetadataItems = cloudMetadataItems.merging(removedCloudMetadataItems) { _, new in new }
    return mergedMetadataItems
  }

  private func getRemovedItemsFromUserInfo(_ userInfo: [AnyHashable: Any]?) -> CloudContents {
    guard let removedItems = userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] else { return [:] }
    return CloudContents(removedItems.compactMap { metadataItem in
      do {
        var item = try CloudMetadataItem(metadataItem: metadataItem)
        item.isRemoved = true
        return item
      } catch {
        delegate?.didReceiveCloudMonitorError(error)
        return nil
      }
    })
  }

  private func getRemovedItemsFromTrash() throws -> [URL] {
    if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
      return []
    }
    guard let trashDirectoryUrl = ubiquitousDocumentsDirectory?.appendingPathComponent(kTrashDirectoryName) else {
      throw SynchronizationError.containerNotFound
    }
    return try FileManager.default.contentsOfDirectory(at: trashDirectoryUrl, 
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants])
  }
}
