import XCTest
@testable import Organic_Maps__Debug_

class MockLocalDirectoryMonitorDelegate: LocalDirectoryMonitorDelegate {
  var didFinishGatheringExpectation: XCTestExpectation?
  var didUpdateExpectation: XCTestExpectation?
  var didReceiveErrorExpectation: XCTestExpectation?

  func didFinishGathering(contents: LocalContents) {
    didFinishGatheringExpectation?.fulfill()
  }

  func didUpdate(contents: LocalContents) {
    didUpdateExpectation?.fulfill()
  }

  func didReceiveLocalMonitorError(_ error: Error) {
    didReceiveErrorExpectation?.fulfill()
  }
}

final class DefaultLocalDirectoryMonitorTests: XCTestCase {

  var directoryMonitor: DefaultLocalDirectoryMonitor!
  var mockDelegate: MockLocalDirectoryMonitorDelegate!
  let tempDirectoryName = UUID().uuidString

  override func setUp() {
    super.setUp()
    // Setup with a temporary directory and a mock delegate
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(tempDirectoryName)
    directoryMonitor = DefaultLocalDirectoryMonitor(directory: tempDirectory, matching: kKMLTypeIdentifier, requestedResourceKeys: [.nameKey])
    mockDelegate = MockLocalDirectoryMonitorDelegate()
    directoryMonitor.delegate = mockDelegate
  }

  override func tearDown() {
    directoryMonitor.stop()
    mockDelegate = nil
    super.tearDown()
  }

  func testInitialization() {
    XCTAssertEqual(directoryMonitor.directory, FileManager.default.temporaryDirectory.appendingPathComponent(tempDirectoryName), "Monitor initialized with incorrect directory.")
    XCTAssertFalse(directoryMonitor.isStarted, "Monitor should not be started initially.")
    XCTAssertTrue(directoryMonitor.isPaused, "Monitor should be paused initially.")
  }

  func testStartMonitoring() {
    let startExpectation = expectation(description: "Start monitoring")
    directoryMonitor.start { result in
      switch result {
      case .success:
        XCTAssertTrue(self.directoryMonitor.isStarted, "Monitor should be started.")
        XCTAssertFalse(self.directoryMonitor.isPaused, "Monitor should not be paused after starting.")
      case .failure(let error):
        XCTFail("Monitoring failed to start with error: \(error)")
      }
      startExpectation.fulfill()
    }
    wait(for: [startExpectation], timeout: 5.0)
  }

  func testStopMonitoring() {
    directoryMonitor.start()
    directoryMonitor.stop()
    XCTAssertFalse(directoryMonitor.isStarted, "Monitor should be stopped.")
    XCTAssertTrue(directoryMonitor.contents.isEmpty, "Contents should be cleared after stopping.")
  }

  func testPauseAndResumeMonitoring() {
    directoryMonitor.start()
    directoryMonitor.pause()
    XCTAssertTrue(directoryMonitor.isPaused, "Monitor should be paused.")

    directoryMonitor.resume()
    XCTAssertFalse(directoryMonitor.isPaused, "Monitor should be resumed.")
  }

  func testDelegateDidFinishGathering() {
    mockDelegate.didFinishGatheringExpectation = expectation(description: "didFinishGathering called")
    directoryMonitor.start()
    wait(for: [mockDelegate.didFinishGatheringExpectation!], timeout: 5.0)
  }

  func testDelegateDidReceiveError() {
    mockDelegate.didReceiveErrorExpectation = expectation(description: "didReceiveLocalMonitorError called")

    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
    directoryMonitor.delegate?.didReceiveLocalMonitorError(error)

    wait(for: [mockDelegate.didReceiveErrorExpectation!], timeout: 1.0)
  }

  func testContentUpdateDetection() {
    let startExpectation = expectation(description: "Start monitoring")
    directoryMonitor.start { result in
      if case .success = result {
        XCTAssertTrue(self.directoryMonitor.isStarted, "Monitor should be started.")
      }
      startExpectation.fulfill()
    }
    wait(for: [startExpectation], timeout: 5.0)

    let fileURL = directoryMonitor.directory.appendingPathComponent("test.kml")
    FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)

    mockDelegate.didUpdateExpectation = expectation(description: "didUpdate called")
    wait(for: [mockDelegate.didUpdateExpectation!], timeout: 5.0)

    XCTAssertTrue(directoryMonitor.contents.contains { $0.fileUrl == fileURL }, "Contents should contain the newly added file.")
  }
}
