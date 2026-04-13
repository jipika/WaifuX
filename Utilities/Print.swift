import Foundation

/// 全局 print 包装器
/// - Debug: 原样输出
/// - Release: 空操作（不产生任何输出）
@inlinable
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
#endif
}
