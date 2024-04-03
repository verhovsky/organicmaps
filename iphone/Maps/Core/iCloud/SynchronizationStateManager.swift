typealias MetadataItemName = String
typealias LocalContents = [LocalMetadataItem]
typealias CloudContents = [CloudMetadataItem]

protocol SynchronizationStateManager {
  var currentLocalContents: LocalContents { get }
  var currentCloudContents: CloudContents { get }
  var localContentsGatheringIsFinished: Bool { get }
  var cloudContentGatheringIsFinished: Bool { get }

  @discardableResult
  func resolveEvent(_ event: IncomingEvent) -> [OutgoingEvent]
  func resetState()
}

enum IncomingEvent {
  case didFinishGatheringLocalContents(LocalContents)
  case didFinishGatheringCloudContents(CloudContents)
  case didUpdateLocalContents(LocalContents)
  case didUpdateCloudContents(CloudContents)
}

enum SynchronizationError: Error {
  case fileUnavailable
  case fileNotUploadedDueToQuota
  case ubiquityServerNotAvailable
  case iCloudIsNotAvailable
  case containerNotFound
  case `internal`(Error)
}

enum OutgoingEvent {
  case createLocalItem(CloudMetadataItem)
  case updateLocalItem(CloudMetadataItem)
  case removeLocalItem(CloudMetadataItem)
  case startDownloading(CloudMetadataItem)
  case resolveVersionsConflict(CloudMetadataItem)
  case createCloudItem(LocalMetadataItem)
  case updateCloudItem(LocalMetadataItem)
  case removeCloudItem(LocalMetadataItem)
  case didReceiveError(SynchronizationError)
}

final class DefaultSynchronizationStateManager: SynchronizationStateManager {

  private(set) var currentLocalContents: LocalContents = []
  private(set) var currentCloudContents: CloudContents = []
  private(set) var localContentsGatheringIsFinished = false
  private(set) var cloudContentGatheringIsFinished = false

  @discardableResult
  func resolveEvent(_ event: IncomingEvent) -> [OutgoingEvent] {
    let outgoingEvents: [OutgoingEvent]
    switch event {
    case .didFinishGatheringLocalContents(let contents):
      localContentsGatheringIsFinished = true
      outgoingEvents = resolveDidFinishGathering(localContents: contents, cloudContents: currentCloudContents)
    case .didFinishGatheringCloudContents(let contents):
      cloudContentGatheringIsFinished = true
      outgoingEvents = resolveDidFinishGathering(localContents: currentLocalContents, cloudContents: contents)
    case .didUpdateLocalContents(let contents):
      outgoingEvents = resolveDidUpdateLocalContents(contents)
    case .didUpdateCloudContents(let contents):
      outgoingEvents = resolveDidUpdateCloudContents(contents)
    }
    return outgoingEvents
  }

  func resetState() {
    currentLocalContents.removeAll()
    currentCloudContents.removeAll()
    localContentsGatheringIsFinished = false
    cloudContentGatheringIsFinished = false
  }

  // MARK: - Private
  private func resolveDidFinishGathering(localContents: LocalContents, cloudContents: CloudContents) -> [OutgoingEvent] {
    currentLocalContents = localContents
    currentCloudContents = cloudContents
    guard localContentsGatheringIsFinished, cloudContentGatheringIsFinished else { return [] }

    let outgoingEvents: [OutgoingEvent]
    switch (localContents.isEmpty, cloudContents.isEmpty) {
    case (true, true):
      outgoingEvents = []
    case (true, false):
      outgoingEvents = cloudContents.notTrashed.map { .createLocalItem($0) }
    case (false, true):
      outgoingEvents = localContents.map { .createCloudItem($0) }
    case (false, false):
      outgoingEvents = resolveDidUpdateCloudContents(cloudContents) + resolveDidUpdateLocalContents(localContents)
    }
    return outgoingEvents
  }

  private func resolveDidUpdateLocalContents(_ localContents: LocalContents) -> [OutgoingEvent] {
    let itemsToRemoveFromCloudContainer = Self.getItemsToRemoveFromCloudContainer(currentLocalContents: currentLocalContents, newLocalContents: localContents)
    let itemsToCreateInCloudContainer = Self.getItemsToCreateInCloudContainer(cloudContents: currentCloudContents, localContents: localContents)
    let itemsToUpdateInCloudContainer = Self.getItemsToUpdateInCloudContainer(cloudContents: currentCloudContents, localContents: localContents)

    var outgoingEvents = [OutgoingEvent]()
    itemsToRemoveFromCloudContainer.forEach { outgoingEvents.append(.removeCloudItem($0)) }
    itemsToCreateInCloudContainer.forEach { outgoingEvents.append(.createCloudItem($0)) }
    itemsToUpdateInCloudContainer.forEach { outgoingEvents.append(.updateCloudItem($0)) }

    currentLocalContents = localContents
    return outgoingEvents
  }

  private func resolveDidUpdateCloudContents(_ cloudContents: CloudContents) -> [OutgoingEvent] {
    var outgoingEvents = [OutgoingEvent]()

    // 1. Handle errors
    let errors = Self.getItemsWithErrors(cloudContents)
    errors.forEach { outgoingEvents.append(.didReceiveError($0)) }

    // TODO: Handle situation when file was removed from one storage and updated in another in offline
    // 2. Handle merge conflicts
    let itemsWithUnresolvedConflicts = Self.getItemsToResolveConflicts(cloudContents: cloudContents)
    itemsWithUnresolvedConflicts.forEach { outgoingEvents.append(.resolveVersionsConflict($0)) }

    guard itemsWithUnresolvedConflicts.isEmpty else {
      return outgoingEvents
    }

    let itemsToRemoveFromLocalContainer = Self.getItemsToRemoveFromLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)
    let itemsToCreateInLocalContainer = Self.getItemsToCreateInLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)
    let itemsToUpdateInLocalContainer = Self.getItemsToUpdateInLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)

    // 3. Handle not downloaded items
    itemsToCreateInLocalContainer.notDownloaded.forEach { outgoingEvents.append(.startDownloading($0)) }
    itemsToUpdateInLocalContainer.notDownloaded.forEach { outgoingEvents.append(.startDownloading($0)) }

    // 4. Handle downloaded items
    itemsToRemoveFromLocalContainer.forEach { outgoingEvents.append(.removeLocalItem($0)) }
    itemsToCreateInLocalContainer.downloaded.forEach { outgoingEvents.append(.createLocalItem($0)) }
    itemsToUpdateInLocalContainer.downloaded.forEach { outgoingEvents.append(.updateLocalItem($0)) }

    currentCloudContents = cloudContents
    return outgoingEvents
  }

  private static func getItemsToRemoveFromCloudContainer(currentLocalContents: LocalContents, newLocalContents: LocalContents) -> LocalContents {
    currentLocalContents.filter { !newLocalContents.containsByName($0) }
  }

  private static func getItemsToCreateInCloudContainer(cloudContents: CloudContents, localContents: LocalContents) -> LocalContents {
    localContents.reduce(into: LocalContents()) { result, localItem in
      if !cloudContents.containsByName(localItem) {
        result.append(localItem)
      } else if !cloudContents.notTrashed.containsByName(localItem),
                let trashedCloudItem = cloudContents.trashed.firstByName(localItem),
                trashedCloudItem.lastModificationDate < localItem.lastModificationDate {
        // If Cloud .Trash contains item and it's last modification date is less than the local item's last modification date than file should be recreated.
        result.append(localItem)
      }
    }
  }

  private static func getItemsToUpdateInCloudContainer(cloudContents: CloudContents, localContents: LocalContents) -> LocalContents {
    localContents.reduce(into: LocalContents()) { result, localItem in
      if let cloudItem = cloudContents.notTrashed.firstByName(localItem),
         localItem.lastModificationDate > cloudItem.lastModificationDate {
        result.append(localItem)
      }
    }
  }


  private static func getItemsWithErrors(_ cloudContents: CloudContents) -> [SynchronizationError] {
     cloudContents.reduce(into: [SynchronizationError](), { partialResult, cloudItem in
      if let downloadingError = cloudItem.downloadingError {
        partialResult.append(SynchronizationError.fromError(downloadingError))
      }
      if let uploadingError = cloudItem.uploadingError {
        partialResult.append(SynchronizationError.fromError(uploadingError))
      }
    })
  }

  private static func getItemsToRemoveFromLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.trashed.reduce(into: CloudContents()) { result, cloudItem in
      // Items shouldn't be removed if newer version of the item isn't in the trash.
      if let notTrashedCloudItem = cloudContents.notTrashed.firstByName(cloudItem), notTrashedCloudItem.lastModificationDate > cloudItem.lastModificationDate {
        return
      }
      if let localItemValue = localContents.firstByName(cloudItem),
         cloudItem.lastModificationDate >= localItemValue.lastModificationDate {
        result.append(cloudItem)
      }
    }
  }

  private static func getItemsToCreateInLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.notTrashed.withUnresolvedConflicts(false).filter { !localContents.containsByName($0) }
  }

  private static func getItemsToUpdateInLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.notTrashed.withUnresolvedConflicts(false).reduce(into: CloudContents()) { result, cloudItem in
      if let localItemValue = localContents.firstByName(cloudItem),
         cloudItem.lastModificationDate > localItemValue.lastModificationDate {
        result.append(cloudItem)
      }
    }
  }

  private static func getItemsToResolveConflicts(cloudContents: CloudContents) -> CloudContents {
    cloudContents.notTrashed.withUnresolvedConflicts(true)
  }
}

// MARK: - MetadataItem Dictionary + Contains
extension Array where Element: MetadataItem {
  func containsByName(_ item: any MetadataItem) -> Bool {
    return contains(where: { $0.fileName == item.fileName })
  }
  func firstByName(_ item: any MetadataItem) -> Element? {
    return first(where: { $0.fileName == item.fileName })
  }
}

// MARK: - CloudMetadataItem Dictionary + Trash, Down
extension Array where Element == CloudMetadataItem {
  var trashed: Self {
    filter { $0.isRemoved }
  }

  var notTrashed: Self {
    filter { !$0.isRemoved }
  }

  var downloaded: Self {
    filter { $0.isDownloaded }
  }

  var notDownloaded: Self {
    filter { !$0.isDownloaded }
  }

  func withUnresolvedConflicts(_ hasUnresolvedConflicts: Bool) -> Self {
    filter { $0.hasUnresolvedConflicts == hasUnresolvedConflicts }
  }
}

// MARK: - SyncronizationError + FromError
private extension SynchronizationError {
  static func fromError(_ error: Error) -> SynchronizationError {
    let nsError = error as NSError
    switch nsError.code {
      // NSURLUbiquitousItemDownloadingErrorKey contains an error with this code when the item has not been uploaded to iCloud by the other devices yet
    case NSUbiquitousFileUnavailableError:
      return .fileUnavailable
      // NSURLUbiquitousItemUploadingErrorKey contains an error with this code when the item has not been uploaded to iCloud because it would make the account go over-quota
    case NSUbiquitousFileNotUploadedDueToQuotaError:
      return .fileNotUploadedDueToQuota
      // NSURLUbiquitousItemDownloadingErrorKey and NSURLUbiquitousItemUploadingErrorKey contain an error with this code when connecting to the iCloud servers failed
    case NSUbiquitousFileUbiquityServerNotAvailable:
      return .ubiquityServerNotAvailable
    default:
      return .internal(error)
    }
  }
}
