import Foundation

@main
enum VideoRendererScreenRoutingTests {
    static func main() {
        typealias Screen = VideoRendererScreenRouting.Screen
        let firstTopology = [
            Screen(identifier: "display-A", fingerprint: "physical-A"),
            Screen(identifier: "display-B", fingerprint: "physical-B")
        ]
        let swappedTopology = [firstTopology[1], firstTopology[0]]

        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "display-A", screens: firstTopology
        ) == 0)
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "display-A", screens: swappedTopology
        ) == 1)
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "missing-display", screens: swappedTopology
        ) == nil, "an old index must never select another physical screen")

        let renumbered = [Screen(identifier: "display-C", fingerprint: "physical-A")]
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "physical-A", screens: renumbered
        ) == 0)
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "display-A", screens: renumbered, previousScreens: firstTopology
        ) == 0, "a previously owned display must survive CG display ID renumbering")
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "display-B", screens: renumbered, previousScreens: firstTopology
        ) == nil, "an unplugged display must not hijack another display")

        let ambiguous = [
            Screen(identifier: "display-C", fingerprint: "identical-monitor"),
            Screen(identifier: "display-D", fingerprint: "identical-monitor")
        ]
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "identical-monitor", screens: ambiguous
        ) == nil, "ambiguous fingerprint must be rejected")
        precondition(VideoRendererScreenRouting.resolvedIndex(
            stableID: "display-A", screens: ambiguous,
            previousScreens: [Screen(identifier: "display-A", fingerprint: "identical-monitor")]
        ) == nil, "a historical match must not select an ambiguous current display")

        print("Video renderer screen routing passed: reorder, stale ID, renumber and ambiguity")
    }
}
