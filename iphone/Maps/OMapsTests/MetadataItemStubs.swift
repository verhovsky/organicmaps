@testable import Organic_Maps__Debug_

extension LocalMetadataItem {
  static func stub(fileName: String, lastModificationDate: Date) -> LocalMetadataItem {
    let item = LocalMetadataItem(fileName: fileName,
                                 fileUrl: URL(string: "url")!,
                                 fileSize: 0,
                                 contentType: "",
                                 creationDate: Date(),
                                 lastModificationDate: lastModificationDate)
    return item

  }
}

extension CloudMetadataItem {
  static func stub(fileName: String, lastModificationDate: Date, isInTrash: Bool, isDownloaded: Bool = true) -> CloudMetadataItem {
    let item = CloudMetadataItem(fileName: fileName,
                                 fileUrl: URL(string: "url")!,
                                 fileSize: 0,
                                 contentType: "",
                                 isDownloaded: isDownloaded,
                                 downloadAmount: 100.0,
                                 creationDate: Date(),
                                 lastModificationDate: lastModificationDate, 
                                 isInTrash: isInTrash)
    return item
  }
}
