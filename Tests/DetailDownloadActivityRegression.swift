import Foundation

@main
struct DetailDownloadActivityRegression {
    static func main() {
        var activity = DetailDownloadActivity()
        let firstItemID = "media-first"
        let secondItemID = "media-second"

        activity.start(itemID: firstItemID)
        precondition(activity.isDownloading(itemID: firstItemID))
        precondition(!activity.isDownloading(itemID: secondItemID))

        // Switching the detail from the first item to the second must not
        // transfer the first item's spinner to the second item.
        activity.start(itemID: secondItemID)
        activity.finish(itemID: firstItemID)
        precondition(!activity.isDownloading(itemID: firstItemID))
        precondition(activity.isDownloading(itemID: secondItemID))

        activity.finish(itemID: secondItemID)
        precondition(!activity.isDownloading(itemID: secondItemID))
        print("DetailDownloadActivity regression passed")
    }
}
