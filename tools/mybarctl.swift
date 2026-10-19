// Send a debug command to a running MyBar debug build and print the JSON result.
// usage: mybarctl <command...>   (waits up to 60 s for the result file to change)
import Foundation
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
let out = "/tmp/mybar-debug.json"
let before = (try? FileManager.default.attributesOfItem(atPath: out)[.modificationDate] as? Date) ?? .distantPast
DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("dev.gimbap.mybar.debug"), object: command, userInfo: nil, deliverImmediately: true)
let deadline = Date().addingTimeInterval(60)
while Date() < deadline {
  if let modified = try? FileManager.default.attributesOfItem(atPath: out)[.modificationDate] as? Date, modified > before {
    usleep(100_000)
    print(String(decoding: FileManager.default.contents(atPath: out) ?? Data(), as: UTF8.self))
    exit(0)
  }
  usleep(200_000)
}
print("timeout waiting for MyBar")
exit(1)
