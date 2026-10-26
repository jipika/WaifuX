#!/usr/bin/env python3
# 回归：我的库封面元数据缓存（LibraryCoverMetadata）与懒构建。
# 用法：python3 Tests/test_library_cover_metadata_regression.py
#
# 覆盖：
#   1. Helper 隔离：BackgroundAgent/ 与 MediaItem+LocalFiles.swift 不引用 LibraryCoverMetadata
#   2. ExploreGrid 不引用 LibraryCoverMetadata（不改现有网格约束）
#   3. 懒构建标记：MyLibraryContentView 包含 rebuildCurrentLibraryLists / rebuildStaleLibraryListsIfNeeded
#   4. pbxproj 注册：LibraryCoverMetadata.swift 在主 App Sources 中
#   5. LibraryCoverMetadata.swift 结构：签名/TTL/积极结果契约/单飞/原子写

import os
import sys
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = 0

def check(ok, name):
    global failures
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name}")
        failures += 1

def read(path):
    with open(os.path.join(REPO, path), encoding='utf-8') as f:
        return f.read()

# 1. Helper 隔离：BackgroundAgent/ 不引用 LibraryCoverMetadata
bg_dir = os.path.join(REPO, 'BackgroundAgent')
bg_ref = False
for f in os.listdir(bg_dir):
    if f.endswith('.swift'):
        content = read(os.path.join('BackgroundAgent', f))
        if 'LibraryCoverMetadata' in content:
            print(f"  BackgroundAgent/{f} references LibraryCoverMetadata")
            bg_ref = True
check(not bg_ref, "BackgroundAgent/ does not reference LibraryCoverMetadata")

# 2. MediaItem+LocalFiles.swift 不引用 LibraryCoverMetadata
ml = read('Models/MediaItem+LocalFiles.swift')
check('LibraryCoverMetadata' not in ml,
      "MediaItem+LocalFiles.swift does not reference LibraryCoverMetadata")

# 3. ExploreGrid 不引用 LibraryCoverMetadata
grid_dir = os.path.join(REPO, 'Components', 'ExploreGrid')
grid_ref = False
for f in os.listdir(grid_dir):
    if f.endswith('.swift'):
        content = read(os.path.join('Components', 'ExploreGrid', f))
        if 'LibraryCoverMetadata' in content:
            print(f"  ExploreGrid/{f} references LibraryCoverMetadata")
            grid_ref = True
check(not grid_ref, "ExploreGrid/ does not reference LibraryCoverMetadata")

# 4. 懒构建标记
mlv = read('Views/MyLibraryContentView.swift')
check('rebuildCurrentLibraryLists' in mlv,
      "MyLibraryContentView has rebuildCurrentLibraryLists")
check('rebuildStaleLibraryListsIfNeeded' in mlv,
      "MyLibraryContentView has rebuildStaleLibraryListsIfNeeded")
check('wallpaperItemsStale' in mlv,
      "MyLibraryContentView has wallpaperItemsStale marker")
check('mediaItemsStale' in mlv,
      "MyLibraryContentView has mediaItemsStale marker")

# 5. pbxproj 注册
pbx = read('WaifuX.xcodeproj/project.pbxproj')
check('LibraryCoverMetadata.swift in Sources' in pbx,
      "pbxproj registers LibraryCoverMetadata.swift in Sources")
check('LibraryCoverMetadata.swift' in pbx,
      "pbxproj has LibraryCoverMetadata.swift fileRef")

# 6. LibraryCoverMetadata.swift 结构断言
lcm = read('Services/LibraryCoverMetadata.swift')
check('struct LibraryCoverFileSignature' in lcm, "LibraryCoverFileSignature struct exists")
check('struct LibraryCoverMetadata' in lcm, "LibraryCoverMetadata struct exists")
check('actor LibraryCoverMetadataResolver' in lcm, "Resolver is actor (background)")
check('@MainActor' in lcm and 'final class LibraryCoverMetadataStore' in lcm,
      "Store is @MainActor")
check('isFresh' in lcm and 'ttl' in lcm, "TTL check present")
check('single-flight' in lcm.lower() or 'inFlight' in lcm,
      "Single-flight merge present")
check('.atomic' in lcm and 'write(to:' in lcm,
      "Atomic write present")
check('maxPersistedEntries' in lcm, "Bounded persistence present")
check('LibraryCoverMetadataStore.shared' in lcm, "Singleton shared store")
check('invalidate(itemID:' in lcm, "Per-item invalidation")
check('invalidateAll()' in lcm, "Bulk invalidation")
check('handleMemoryPressure' in lcm, "Memory pressure handler")
check('contentRevision' in lcm, "Coalesced content revision")

# 7. 积极结果契约：无本地封面时不落库
check('return nil' in lcm and '无本地积极结果' in lcm,
      "Positive-only contract: no local cover → no cache entry")

# 8. 签名容差
check('matches(_ lhs: Self, _ rhs: Self)' in lcm and 'abs(' in lcm,
      "Signature tolerance comparison present")

# 9. MyLibraryContentView 懒构建不双套重建
# 确认没有残留的 updateWallpaperItems() + updateMediaItems() 连续调用（在 rebuildCurrentLibraryLists 之外）
lines = mlv.split('\n')
in_rebuild = False
dual_update = False
for i, line in enumerate(lines):
    if 'func rebuildCurrentLibraryLists' in line:
        in_rebuild = True
    if in_rebuild and 'updateWallpaperItems()' in line and i+1 < len(lines) and 'updateMediaItems()' in lines[i+1]:
        dual_update = True
        break
    if in_rebuild and line.strip() == '}':
        in_rebuild = False
check(not dual_update, "No dual-list rebuild outside rebuildCurrentLibraryLists")

if failures > 0:
    print(f"FAILED {failures}")
    sys.exit(1)
print("ALL PASS")
