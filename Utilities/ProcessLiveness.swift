//  进程存活判定与扩展 state 心跳字段提取
//
//  参考 Mirage 健康报告的验活语义：宿主读到 isActive=true 但写状态的
//  扩展进程已死时，可立即清理残留 state，不必等延迟复核。
//
//  本文件保持自包含（仅 Foundation/Darwin），供回归脚本单独编译。

import Darwin
import Foundation

enum ProcessLiveness {
    /// kill(pid, 0) 探测：返回 0 = 存活；EPERM = 存活（无权限发信号，如沙箱进程）；
    /// ESRCH 及其他 = 已死。pid ≤ 0 视为无效。
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 回收「别人拥有」的状态时用这个更保守的判定：只有 ESRCH 才是确定死亡。
    /// EPERM 说明进程存在；pid ≤ 0 与其它探测错误都不能当作死亡证据。
    static func isDefinitelyDead(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) != 0 else { return false }
        return errno == ESRCH
    }

    /// 从扩展 state JSON（JSONSerialization 字典）提取心跳字段。
    /// 旧版扩展写入的文件没有这些键，全部返回 nil（调用方须容忍并走旧逻辑）。
    static func heartbeat(fromJSON json: [String: Any]) -> (pid: Int32?, lastError: String?) {
        let pid = (json["pid"] as? NSNumber)?.int32Value
        let lastError = json["lastError"] as? String
        return (pid, lastError)
    }
}
