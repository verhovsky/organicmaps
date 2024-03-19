protocol MetadataItem: Equatable, Hashable {
  var fileName: String { get }
  var fileUrl: URL { get }
  var fileSize: Int? { get }
  var contentType: String { get }
  var creationDate: Date { get }
  var lastModificationDate: Date { get }
}

extension MetadataItem {
  var exists: Bool {
    FileManager.default.fileExists(atPath: fileUrl.path)
  }
}

struct CloudMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int?
  let contentType: String
  let isDownloaded: Bool
  let downloadAmount: Double?
  let isUploading: Bool
  let isUploaded: Bool
  let creationDate: Date
  let lastModificationDate: Date
  let isInTrash: Bool

  // TODO: remove force unwraps
  init(metadataItem: NSMetadataItem) {
    fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as! String
    fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as! URL
    fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int
    contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as! String
    downloadAmount = metadataItem.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
    let downloadStatus = metadataItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
    isDownloaded = downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent
    let uploaded = metadataItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool ?? false
    isUploading = metadataItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? true
    isUploaded = uploaded && !isUploading
    creationDate = metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as! Date
    lastModificationDate = metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as! Date
    isInTrash = fileUrl.pathComponents.contains(kTrashDirectoryName)
  }
}

struct LocalMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int?
  let contentType: String
  let creationDate: Date
  let lastModificationDate: Date

  // TODO: remove force unwraps
  init(metadataItem: NSMetadataItem) {
    fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as! String
    fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as! URL
    fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int
    contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as! String
    creationDate = metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as! Date
    lastModificationDate = metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as! Date
  }

  // TODO: remove force unwraps
  init(fileUrl: URL) {
    fileName = fileUrl.lastPathComponent
    self.fileUrl = fileUrl
    fileSize = try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize
    contentType = try! fileUrl.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier!
    creationDate = try! fileUrl.resourceValues(forKeys: [.creationDateKey]).creationDate!
    lastModificationDate = try! fileUrl.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
  }

  var fileData: Data {
    if let data = try? Data(contentsOf: fileUrl) {
      return data
    } else {
      // TODO: handle error
      fatalError("Could not read file data")
    }
  }
}
