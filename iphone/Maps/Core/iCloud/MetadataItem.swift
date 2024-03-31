protocol MetadataItem: Equatable, Hashable {
  var fileName: String { get }
  var fileUrl: URL { get }
  var fileSize: Int { get }
  var contentType: String { get }
  var creationDate: TimeInterval { get }
  var lastModificationDate: TimeInterval { get }
}

struct LocalMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int
  let contentType: String
  let creationDate: TimeInterval
  let lastModificationDate: TimeInterval
}

struct CloudMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int
  let contentType: String
  var isDownloaded: Bool
  let creationDate: TimeInterval
  var lastModificationDate: TimeInterval
  var isInTrash: Bool
  let downloadingError: NSError?
  let uploadingError: NSError?
  let hasUnresolvedConflicts: Bool
}

extension LocalMetadataItem {
  init(metadataItem: NSMetadataItem) throws {
    guard let fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as? String,
          let fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as? URL,
          let fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int,
          let contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
          let creationDate = (metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)?.timeIntervalSince1970.rounded(.down),
          let lastModificationDate = (metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970.rounded(.down) else {
      throw NSError(domain: "LocalMetadataItem", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize LocalMetadataItem from NSMetadataItem"])
    }
    self.fileName = fileName
    self.fileUrl = fileUrl
    self.fileSize = fileSize
    self.contentType = contentType
    self.creationDate = creationDate
    self.lastModificationDate = lastModificationDate
  }

  init(fileUrl: URL) throws {
    let resources = try fileUrl.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey, .contentModificationDateKey, .creationDateKey])
    guard let fileSize = resources.fileSize,
          let contentType = resources.typeIdentifier,
          let creationDate = resources.creationDate?.timeIntervalSince1970.rounded(.down),
          let lastModificationDate = resources.contentModificationDate?.timeIntervalSince1970.rounded(.down) else {
      throw NSError(domain: "LocalMetadataItem", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize LocalMetadataItem from URL"])
    }
    self.fileName = fileUrl.lastPathComponent
    self.fileUrl = fileUrl
    self.fileSize = fileSize
    self.contentType = contentType
    self.creationDate = creationDate
    self.lastModificationDate = lastModificationDate
  }

  func fileData() throws -> Data {
    try Data(contentsOf: fileUrl)
  }
}

extension CloudMetadataItem {
  init(metadataItem: NSMetadataItem) throws {
    guard let fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as? String,
          let fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as? URL,
          let fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int,
          let contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
          let downloadStatus = metadataItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
          let creationDate = (metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)?.timeIntervalSince1970.rounded(.down),
          let lastModificationDate = (metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970.rounded(.down),
          let hasUnresolvedConflicts = metadataItem.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool else {
      throw NSError(domain: "CloudMetadataItem", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize CloudMetadataItem from NSMetadataItem"])
    }
    self.fileName = fileName
    self.fileUrl = fileUrl
    self.fileSize = fileSize
    self.contentType = contentType
    self.isDownloaded = downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent
    self.creationDate = creationDate
    self.lastModificationDate = lastModificationDate
    self.isInTrash = false
    self.hasUnresolvedConflicts = hasUnresolvedConflicts
    self.downloadingError = metadataItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? NSError
    self.uploadingError = metadataItem.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError
  }

  init(fileUrl: URL) throws {
    let resources = try fileUrl.resourceValues(forKeys: [.nameKey, .fileSizeKey, .typeIdentifierKey, .contentModificationDateKey, .creationDateKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey])
    guard let fileSize = resources.fileSize,
          let contentType = resources.typeIdentifier,
          let creationDate = resources.creationDate?.timeIntervalSince1970.rounded(.down),
          let downloadStatus = resources.ubiquitousItemDownloadingStatus,
          let lastModificationDate = resources.contentModificationDate?.timeIntervalSince1970.rounded(.down),
          let hasUnresolvedConflicts = resources.ubiquitousItemHasUnresolvedConflicts else {
      throw NSError(domain: "CloudMetadataItem", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize CloudMetadataItem from NSMetadataItem"])
    }
    self.fileName = fileUrl.lastPathComponent
    self.fileUrl = fileUrl
    self.fileSize = fileSize
    self.contentType = contentType
    self.isDownloaded = downloadStatus.rawValue == NSMetadataUbiquitousItemDownloadingStatusCurrent
    self.creationDate = creationDate
    self.lastModificationDate = lastModificationDate
    self.isInTrash = false
    self.hasUnresolvedConflicts = hasUnresolvedConflicts
    self.downloadingError = resources.ubiquitousItemDownloadingError
    self.uploadingError = resources.ubiquitousItemUploadingError
  }
}
