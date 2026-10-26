#!/usr/bin/env python3
# 回归：我的库「假空态」与「库快照迟到」修复（2026-10-26）。
# 用法：python3 Tests/test_library_snapshot_gate_regression.py
#
# 钉住的契约：
#   1. 骨架显隐只看「快照到没到 + 本页构建过没」，不再用固定 1.2s 超时塌成空态
#   2. 快照到达位只在非空载荷上置位；断连时回落
#   3. 首屏快速读通道必须两侧同时闸门（UI 发过库写就永久排队；
#      Helper 未恢复完 或 队里有库写就不越队）
#   4. 越队的读不写 commandTail（否则会挡住后续写）
#   5. 空库 ≠ 加载中：空态文案只在快照到达后可见
#   6. 不出现编译期不存在的 CocoaError.Code（-parse 抓不到，必须靠源码断言）

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = 0


def check(ok, name):
    global failures
    print(f"{'PASS' if ok else 'FAIL'} {name}")
    if not ok:
        failures += 1


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as f:
        return f.read()


view = read("Views/MyLibraryContentView.swift")
client = read("BackgroundAgent/BackgroundAgentClient.swift")
runtime = read("BackgroundAgent/BackgroundAgentRuntime.swift")

# --- 1. 旧的超时兜底与跨类型判据必须彻底移除 ---
check("libraryFirstLoadIsReady" not in view, "旧 libraryFirstLoadIsReady（跨类型取或）已移除")
check("libraryDataSourceHasAnyRecords" not in view, "旧 libraryDataSourceHasAnyRecords 已移除")
check("addingTimeInterval(1.2)" not in view, "1.2s 骨架超时兜底已移除")
check("placeholderDeadline" not in view, "固定占位截止时间已移除")
check(view.count("if libraryGridPlaceholderVisible {") == 2,
      "壁纸页与媒体页都改用 libraryGridPlaceholderVisible")
check("if libraryFirstLoadPlaceholderVisible && !hasActiveLibrarySearch {" not in view,
      "段内不再直接消费一次性首屏布尔")

# --- 2. 到达位的唯一写点 + 空载荷防御 ---
check(len(re.findall(r"librarySnapshotIsArrived = true", client)) == 1,
      "到达位只在 applyLibrarySnapshot 内置位")
guard = re.search(r"private func applyLibrarySnapshot\(_ values: \[String: Any\]\) \{\s*guard !values\.isEmpty else \{ return \}",
                  client)
check(guard is not None, "空载荷不会被记成已到达（避免空库被反向误判）")
reset = client[client.index("private func resetLibraryFetch"):][:400]
check("latestLibrary = [:]" in reset and "librarySnapshotIsArrived = false" in reset,
      "断连时快照缓存与到达位一起回落")
# 赋值点只允许出现在 applyLibrarySnapshot（= values）与 resetLibraryFetch（= [:]）
assigns = re.findall(r"^\s+latestLibrary = ([^\n]+)", client, re.M)
# resetLibraryFetch 置空 + applyLibrarySnapshot 置载荷；observeLibrary 补发只读不写。
check(assigns == ["[:]", "values"],
      f"快照载荷只在两处赋值（reset 置空 / apply 写入）（实际：{assigns}）")
check(client.count("for handler in libraryHandlers") == 1,
      "广播点收敛到唯一一处（applyLibrarySnapshot）")

# --- 3. 两侧闸门 ---
check("guard libraryRecordsAreRestored else" in runtime,
      "Helper 侧：未恢复完拒绝提前应答 library.snapshot")
iso = runtime[runtime.index("if BackgroundRuntimeRole.isIsolatedTest {"):]
check("libraryRecordsAreRestored = true" in iso[:300],
      "Helper 侧：隔离测试分支也打开闸门（否则回归 RPC 被新 guard 拒掉）")
restore_idx = runtime.index("LibraryFolderStore.shared.sanitizeLibraryFolderMemberships()")
flag_idx = runtime.index("libraryRecordsAreRestored = true", restore_idx)
check(flag_idx - restore_idx < 300, "Helper 侧：闸门在库恢复序列末尾打开")
check("pendingLibraryMutations == 0" in runtime,
      "Helper 侧：队里有库写时不越队")
bypass = runtime[runtime.index("let isLibrarySnapshotRead"):][:300]
check("libraryRecordsAreRestored" in bypass and "pendingLibraryMutations == 0" in bypass,
      "Helper 侧：越队条件同时要求已恢复 + 无在飞写")
check("hasSentLibraryMutation" in client, "UI 侧：存在库写后永久走正常排队")
enq = client[client.index("private func enqueue"):][:700]
check("hasSentLibraryMutation = true" in enq,
      "UI 侧：关闭快速通道发生在入队（同步）而非任务体")
check('operation != "library.snapshot"' in enq,
      "UI 侧：library.snapshot 自身不算写，不会自锁")

# --- 4. 越队的读不得占用队尾 ---
check("!isLibrarySnapshotRead" in runtime,
      "Helper 侧：越队读不写 commandTail")
check("skipCommandTail: true, skipBootstrap: true" in client,
      "UI 侧：快速读不等 bootstrapTask（否则回到慢路径）")
check("librarySnapshotTimeoutSeconds" in client,
      "快速读带显式短超时（默认 120s 会让重试阶梯失准）")

# --- 5. 看门狗与世代号 ---
check("defer {\n                if generation == librarySnapshotFetchGeneration" in view,
      "拉取任务只清自己世代的句柄")
check(view.count("startLibrarySnapshotFetchIfPending()") >= 3,
      ".task / onAppear / 断连回落都会重新起拉取")
check("librarySnapshotWaitTimedOut" in view and "library.backend.unavailable.title" in view,
      "到点仍无快照 → 转「后台服务未连接」而不是假空态")

# --- 6. 缓存就绪再建列表（撤骨架不闪空态） ---
check("awaitLocalLibraryCacheReady" in read("ViewModels/WallpaperViewModel.swift"),
      "WallpaperViewModel 暴露缓存就绪等待")
check("awaitLocalMediaCacheReady" in read("ViewModels/MediaExploreViewModel.swift"),
      "MediaExploreViewModel 暴露缓存就绪等待")
rebuild = view[view.index("private func rebuildCurrentListsAfterCacheReady"):][:700]
check("awaitLocalLibraryCacheReady" in rebuild and "awaitLocalMediaCacheReady" in rebuild,
      "快照到达后先等缓存重建再构建列表")
check("mediaViewModel.isLibraryCachePending" in view,
      "媒体页用媒体 VM 的挂起位（不串用壁纸 VM）")

# --- 7. 编译期不存在的枚举成员（-parse 抓不到） ---
bad_codes = ["featureUnavailable"]
hits = [(p, c) for p, c in (("View", view), ("Client", client), ("Runtime", runtime))
        for b in bad_codes if f".{b}" in c]
check(not hits, f"未使用不存在的 CocoaError.Code（命中：{hits}）")
check("CocoaError(.featureUnsupported" in runtime,
      "library.snapshot 闸门使用仓库既有且可编译的错误码")

print(f"\n{'ALL PASS' if failures == 0 else f'{failures} FAILED'}")
sys.exit(1 if failures else 0)
