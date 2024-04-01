typealias MetadataItemName = String
typealias LocalContents = Dictionary<MetadataItemName, LocalMetadataItem>
typealias CloudContents = Dictionary<MetadataItemName, CloudMetadataItem>

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

  private(set) var currentLocalContents: LocalContents = [:]
  private(set) var currentCloudContents: CloudContents = [:]
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
      outgoingEvents = cloudContents.notRemoved.map { .createLocalItem($0.value) }
    case (false, true):
      outgoingEvents = localContents.map { .createCloudItem($0.value) }
    case (false, false):
      outgoingEvents = resolveDidUpdateCloudContents(cloudContents) + resolveDidUpdateLocalContents(localContents)
    }
    return outgoingEvents
  }

  private func resolveDidUpdateLocalContents(_ localContents: LocalContents) -> [OutgoingEvent] {
    let itemsToRemoveFromCloudContainer = Self.getLocalItemsToRemoveFromCloudContainer(currentLocalContents: currentLocalContents, newLocalContents: localContents)
    let itemsToCreateInCloudContainer = Self.getLocalItemsToCreateInLocalContainer(cloudContents: currentCloudContents, localContents: localContents)
    let itemsToUpdateInCloudContainer = Self.getLocalItemsToUpdateInCloudContainer(cloudContents: currentCloudContents, localContents: localContents)

    var outgoingEvents = [OutgoingEvent]()
    itemsToRemoveFromCloudContainer.forEach { outgoingEvents.append(.removeCloudItem($0.value)) }
    itemsToCreateInCloudContainer.forEach { outgoingEvents.append(.createCloudItem($0.value)) }
    itemsToUpdateInCloudContainer.forEach { outgoingEvents.append(.updateCloudItem($0.value)) }

    currentLocalContents = localContents
    return outgoingEvents
  }

  private func resolveDidUpdateCloudContents(_ cloudContents: CloudContents) -> [OutgoingEvent] {
    var outgoingEvents = [OutgoingEvent]()

    // 1. Handle errors
    let errors = Self.getCloudItemsWithErrors(cloudContents)
    errors.forEach { outgoingEvents.append(.didReceiveError($0)) }

    // 2. Handle merge conflicts
    let itemsWithUnresolvedConflicts = Self.getCloudItemsToResolveConflicts(cloudContents: cloudContents)
    itemsWithUnresolvedConflicts.forEach { outgoingEvents.append(.resolveVersionsConflict($0.value)) }

    guard itemsWithUnresolvedConflicts.isEmpty else {
      return outgoingEvents
    }

    let itemsToRemoveFromLocalContainer = Self.getCloudItemsToRemoveFromLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)
    let itemsToCreateInLocalContainer = Self.getCloudItemsToCreateInLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)
    let itemsToUpdateInLocalContainer = Self.getCloudItemsToUpdateInLocalContainer(cloudContents: cloudContents, localContents: currentLocalContents)

//    itemsWithUnresolvedConflicts.forEach { outgoingEvents.append(.resolveVersionsConflict($0.value)) }
    // TODO: Handle situation when file was removed from one storage and updated in another in offline

    // 3. Handle not downloaded items
    itemsToCreateInLocalContainer.notDownloaded.forEach { outgoingEvents.append(.startDownloading($0.value)) }
    itemsToUpdateInLocalContainer.notDownloaded.forEach { outgoingEvents.append(.startDownloading($0.value)) }

    // 4. Handle downloaded items
    itemsToRemoveFromLocalContainer.forEach { outgoingEvents.append(.removeLocalItem($0.value)) }
    itemsToCreateInLocalContainer.downloaded.forEach { outgoingEvents.append(.createLocalItem($0.value)) }
    itemsToUpdateInLocalContainer.downloaded.forEach { outgoingEvents.append(.updateLocalItem($0.value)) }

    currentCloudContents = cloudContents
    return outgoingEvents
  }

  private static func getLocalItemsToRemoveFromCloudContainer(currentLocalContents: LocalContents, newLocalContents: LocalContents) -> LocalContents {
    currentLocalContents.filter { !newLocalContents.contains($0.key) }
  }

  private static func getLocalItemsToCreateInLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> LocalContents {
    localContents.reduce(into: LocalContents()) { partialResult, localItem in
      if let cloudItemValue = cloudContents[localItem.key] {
        // Merge conflict: if cloud .trash contains item and it's last modification date is less than local item's last modification date than file should be recreated.
        if cloudItemValue.isRemoved, cloudItemValue.lastModificationDate < localItem.value.lastModificationDate {
          partialResult[localItem.key] = localItem.value
        }
      } else {
        partialResult[localItem.key] = localItem.value
      }
    }
  }

  private static func getLocalItemsToUpdateInCloudContainer(cloudContents: CloudContents, localContents: LocalContents) -> LocalContents {
    localContents.reduce(into: LocalContents()) { result, localItem in
      if let cloudItemValue = cloudContents[localItem.key],
         !cloudItemValue.isRemoved,
         localItem.value.lastModificationDate > cloudItemValue.lastModificationDate {
        result[localItem.key] = localItem.value
      }
    }
  }


  private static func getCloudItemsWithErrors(_ cloudContents: CloudContents) -> [SynchronizationError] {
     cloudContents.reduce(into: [SynchronizationError](), { partialResult, cloudItem in
      if let downloadingError = cloudItem.value.downloadingError {
        partialResult.append(SynchronizationError.fromError(downloadingError))
      }
      if let uploadingError = cloudItem.value.uploadingError {
        partialResult.append(SynchronizationError.fromError(uploadingError))
      }
    })
  }

  private static func getCloudItemsToRemoveFromLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.removed.reduce(into: CloudContents()) { result, cloudItem in
      if let localItemValue = localContents[cloudItem.key],
         cloudItem.value.lastModificationDate >= localItemValue.lastModificationDate {
        result[cloudItem.key] = cloudItem.value
      }
    }
  }

  private static func getCloudItemsToCreateInLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.notRemoved.withUnresolvedConflicts(false).filter { !localContents.contains($0.key) }
  }

  private static func getCloudItemsToUpdateInLocalContainer(cloudContents: CloudContents, localContents: LocalContents) -> CloudContents {
    cloudContents.notRemoved.withUnresolvedConflicts(false).reduce(into: CloudContents()) { result, cloudItem in
      if let localItemValue = localContents[cloudItem.key],
         cloudItem.value.lastModificationDate > localItemValue.lastModificationDate {
        result[cloudItem.key] = cloudItem.value
      }
    }
  }

  private static func getCloudItemsToResolveConflicts(cloudContents: CloudContents) -> CloudContents {
    cloudContents.notRemoved.withUnresolvedConflicts(true)
  }
}

// MARK: - MetadataItem Dictionary + Contains
extension Dictionary where Key == MetadataItemName, Value: MetadataItem {
  func contains(_ item: Key) -> Bool {
    return keys.contains(item)
  }

  mutating func add(_ item: Value) {
    self[item.fileName] = item
  }

  init(_ items: [Value]) {
    self.init(uniqueKeysWithValues: items.map { ($0.fileName, $0) })
  }
}

// MARK: - CloudMetadataItem Dictionary + Trash, Down
private extension Dictionary where Key == MetadataItemName, Value == CloudMetadataItem {
  var removed: Self {
    filter { $0.value.isRemoved }
  }

  var notRemoved: Self {
    filter { !$0.value.isRemoved }
  }

  var downloaded: Self {
    filter { $0.value.isDownloaded }
  }

  var notDownloaded: Self {
    filter { !$0.value.isDownloaded }
  }

  func withUnresolvedConflicts(_ hasUnresolvedConflicts: Bool) -> Self {
    filter { $0.value.hasUnresolvedConflicts == hasUnresolvedConflicts }
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
