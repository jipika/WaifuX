import Darwin
import Foundation

guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
    fputs("GROUP_ACCESS_FAILED container unavailable\n", stderr)
    exit(1)
}
let descriptor = open(container.path, O_RDONLY | O_DIRECTORY)
guard descriptor >= 0 else {
    fputs("GROUP_ACCESS_FAILED read permission denied\n", stderr)
    exit(1)
}
close(descriptor)
print("SIGNED_HELPER_GROUP_ACCESS_PASSED readOnly=true")
