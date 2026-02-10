import Foundation
import XCTest

final class AppleScriptTests: XCTestCase {

  // MARK: - Helper to run AppleScript via osascript process (matches plugin implementation)

  private func runAppleScript(_ script: String, timeout: TimeInterval = 15) -> Result<String, Error>
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
      try process.run()
    } catch {
      return .failure(error)
    }

    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
      if process.isRunning { process.terminate() }
    }
    timer.resume()

    process.waitUntilExit()
    timer.cancel()

    let timedOut = process.terminationReason == .uncaughtSignal

    if timedOut {
      return .failure(
        NSError(
          domain: "AppleScriptTest", code: -3,
          userInfo: [
            NSLocalizedDescriptionKey: "AppleScript timed out after \(Int(timeout)) seconds"
          ]))
    }

    if process.terminationStatus != 0 {
      let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      let errMsg =
        String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "Unknown AppleScript error"
      return .failure(
        NSError(
          domain: "AppleScriptTest", code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: errMsg]))
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let output =
      String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return .success(output)
  }

  // MARK: - Basic AppleScript Execution Tests

  func testBasicAppleScriptExecution() throws {
    // Simple test to verify AppleScript engine works
    let script = """
      return "Hello from AppleScript"
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "Hello from AppleScript")
    case .failure(let error):
      XCTFail("AppleScript execution failed: \(error.localizedDescription)")
    }
  }

  func testCalendarAppAccess() throws {
    // Test if Calendar.app is accessible
    let script = """
      tell application "Calendar"
          return name
      end tell
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "Calendar", "Calendar app should return its name")
    case .failure(let error):
      // This may fail if Calendar access is not granted - that's expected in CI
      print("Calendar access test failed (may need permissions): \(error.localizedDescription)")
    }
  }

  // MARK: - ASCII Operator Tests (verifies no encoding issues)

  func testAsciiComparisonOperators() throws {
    // Test that ASCII comparison operators work correctly
    let script = """
      set testDate1 to current date
      set testDate2 to current date

      if testDate1 is greater than or equal to testDate2 then
          return "greater_or_equal_works"
      else
          return "failed"
      end if
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "greater_or_equal_works")
    case .failure(let error):
      XCTFail("ASCII comparison operator failed: \(error.localizedDescription)")
    }
  }

  func testAsciiLessThanOrEqualOperator() throws {
    let script = """
      set testDate1 to current date
      set testDate2 to current date

      if testDate1 is less than or equal to testDate2 then
          return "less_or_equal_works"
      else
          return "failed"
      end if
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "less_or_equal_works")
    case .failure(let error):
      XCTFail("ASCII less than or equal operator failed: \(error.localizedDescription)")
    }
  }

  func testAsciiNotEqualOperator() throws {
    let script = """
      set testValue to "hello"

      if testValue is not equal to "" then
          return "not_equal_works"
      else
          return "failed"
      end if
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "not_equal_works")
    case .failure(let error):
      XCTFail("ASCII not equal operator failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Calendar Query Structure Tests

  func testCalendarDateConstruction() throws {
    // Test that date construction in AppleScript works
    let script = """
      set testDate to current date
      set year of testDate to 2024
      set month of testDate to 12
      set day of testDate to 25
      set hours of testDate to 0
      set minutes of testDate to 0
      set seconds of testDate to 0

      return year of testDate as string
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "2024")
    case .failure(let error):
      XCTFail("Date construction failed: \(error.localizedDescription)")
    }
  }

  func testCalendarListAccess() throws {
    // Test accessing calendar list (requires Calendar permissions)
    let script = """
      tell application "Calendar"
          set calCount to count of calendars
          return calCount as string
      end tell
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      // Should return a number (could be 0 if no calendars)
      let count = Int(output)
      XCTAssertNotNil(count, "Should return a valid number")
      print("Found \(output) calendars")
    case .failure(let error):
      // Expected to fail without permissions
      print("Calendar list access failed (may need permissions): \(error.localizedDescription)")
    }
  }

  // MARK: - Event Query Structure Test

  func testEventQueryStructure() throws {
    // Test the event query structure we use (simplified version)
    let script = """
      tell application "Calendar"
          set eventList to {}
          set eventCount to 0
          set maxEvents to 1
          
          set startDate to current date
          set year of startDate to 2024
          set month of startDate to 1
          set day of startDate to 1
          set hours of startDate to 0
          set minutes of startDate to 0
          set seconds of startDate to 0
          
          set endDate to current date
          set year of endDate to 2024
          set month of endDate to 12
          set day of endDate to 31
          set hours of endDate to 23
          set minutes of endDate to 59
          set seconds of endDate to 59
          
          repeat with cal in calendars
              set calName to name of cal
              try
                  set calEvents to (every event of cal whose start date is greater than or equal to startDate and start date is less than or equal to endDate)
                  set eventCount to eventCount + (count of calEvents)
              end try
          end repeat
          
          return eventCount as string
      end tell
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      let count = Int(output)
      XCTAssertNotNil(count, "Should return a valid event count")
      print("Found \(output) events in date range")
    case .failure(let error):
      // May fail without permissions
      print("Event query test failed (may need permissions): \(error.localizedDescription)")
    }
  }

  // MARK: - String Delimiter Test

  func testStringDelimiterHandling() throws {
    // Test the delimiter-based output format we use
    let script = """
      set eventList to {}
      set end of eventList to "id1|||title1|||calendar1|||date1|||date2|||false|||location1|||notes1|||url1"
      set end of eventList to "id2|||title2|||calendar2|||date3|||date4|||true|||location2|||notes2|||url2"

      set AppleScript's text item delimiters to "###"
      return eventList as string
      """

    let result = runAppleScript(script)

    switch result {
    case .success(let output):
      XCTAssertTrue(output.contains("###"), "Should use ### as delimiter")
      XCTAssertTrue(output.contains("|||"), "Should use ||| as field separator")

      let events = output.components(separatedBy: "###")
      XCTAssertEqual(events.count, 2, "Should have 2 events")
    case .failure(let error):
      XCTFail("String delimiter test failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Timeout Behavior Tests

  func testAppleScriptTimeout() throws {
    // A script that sleeps for 5 seconds should be terminated by a 2-second timeout
    let script = """
      delay 5
      return "should not reach here"
      """

    let start = Date()
    let result = runAppleScript(script, timeout: 2)
    let elapsed = Date().timeIntervalSince(start)

    switch result {
    case .success:
      XCTFail("Script should have timed out, not succeeded")
    case .failure(let error):
      XCTAssertTrue(
        error.localizedDescription.contains("timed out"),
        "Error should indicate a timeout, got: \(error.localizedDescription)")
    }

    // Should have completed in roughly 2 seconds, not 5
    XCTAssertLessThan(elapsed, 4.0, "Timeout should have killed the script well before it finished")
  }

  func testAppleScriptCompletesBeforeTimeout() throws {
    // A fast script should succeed even with a short timeout
    let script = """
      return "fast"
      """

    let result = runAppleScript(script, timeout: 5)

    switch result {
    case .success(let output):
      XCTAssertEqual(output, "fast")
    case .failure(let error):
      XCTFail("Fast script should not fail: \(error.localizedDescription)")
    }
  }

  func testAppleScriptSyntaxError() throws {
    // A script with invalid syntax should return an error, not hang
    let script = """
      this is not valid applescript at all !!!
      """

    let result = runAppleScript(script, timeout: 5)

    switch result {
    case .success:
      XCTFail("Invalid script should have failed")
    case .failure:
      // Expected - syntax error returned as failure
      break
    }
  }
}
