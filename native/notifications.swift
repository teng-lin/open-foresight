import Foundation
import UserNotifications

// A separate signed bundle gives reminders a stable notification identity.
// Permission is requested only by an explicit setup action.
let args = Array(CommandLine.arguments.dropFirst())
let center = UNUserNotificationCenter.current()
var finished = false
var result: [String: Any] = [:]
var status: Int32 = 0

func finish(_ value: [String: Any], _ code: Int32 = 0) {
    DispatchQueue.main.async {
        result = value
        status = code
        finished = true
    }
}

func argument(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

if args == ["--request-permission"] {
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        finish(["granted": granted, "error": error?.localizedDescription ?? ""], granted ? 0 : 1)
    }
} else if args == ["--capabilities"] {
    center.getNotificationSettings { settings in
        finish(["authorization": settings.authorizationStatus.rawValue,
                "available": settings.authorizationStatus == .authorized])
    }
} else if args.count == 4, let title = argument("--title"), let message = argument("--message") {
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized else {
            finish(["error": "Notification permission is required. Enable reminders explicitly in notification setup."], 1)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            finish(error == nil ? ["delivered": true] : ["error": error!.localizedDescription], error == nil ? 0 : 1)
        }
    }
} else {
    finish(["error": "Usage: foresight-notifications --capabilities | --request-permission | --title TITLE --message MESSAGE"], 2)
}
let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
if !finished {
    result = ["error": "Notification request timed out"]
    status = 1
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
exit(status)
