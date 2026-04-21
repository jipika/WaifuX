#!/usr/bin/env python3
"""
修复 Resources/lib/ 下 dylib 的依赖路径：
把 @loader_path/lib/xxx 改回 @loader_path/xxx（因为 dylib 已经在 lib/ 里）
"""
import subprocess
import os

LIB = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/lib"

def get_dependencies(dylib_path: str):
    result = subprocess.run(
        ["otool", "-L", dylib_path],
        capture_output=True, text=True, check=True
    )
    deps = []
    for line in result.stdout.strip().split("\n")[1:]:
        line = line.strip()
        if not line:
            continue
        path = line.split(" ")[0]
        if path.startswith("/usr/lib/") or path.startswith("/System/"):
            continue
        if path == dylib_path:
            continue
        deps.append(path)
    return deps

def fix_dylib(path: str):
    basename = os.path.basename(path)
    if os.path.islink(path):
        return

    # 修复 id
    id_result = subprocess.run(
        ["otool", "-D", path], capture_output=True, text=True, check=True
    )
    lines = id_result.stdout.strip().split("\n")
    if len(lines) >= 2:
        current_id = lines[1].strip()
        if current_id.startswith("@loader_path/lib/"):
            new_id = current_id.replace("@loader_path/lib/", "@loader_path/", 1)
            subprocess.run(
                ["install_name_tool", "-id", new_id, path],
                capture_output=True, check=True
            )
            print(f"  {basename}: id -> {new_id}")

    # 修复依赖
    deps = get_dependencies(path)
    for dep in deps:
        if dep.startswith("@loader_path/lib/"):
            new_dep = dep.replace("@loader_path/lib/", "@loader_path/", 1)
            subprocess.run(
                ["install_name_tool", "-change", dep, new_dep, path],
                capture_output=True, check=True
            )
            print(f"  {basename}: {dep} -> {new_dep}")

def main():
    files = sorted(os.listdir(LIB))
    for name in files:
        path = os.path.join(LIB, name)
        if os.path.isfile(path) and name.endswith(".dylib"):
            fix_dylib(path)

    # 重新签名
    print("\nRe-signing...")
    for name in files:
        path = os.path.join(LIB, name)
        if os.path.isfile(path) and name.endswith(".dylib") and not os.path.islink(path):
            subprocess.run(
                ["codesign", "--force", "-s", "-", path],
                capture_output=True, check=False
            )

    print("Done!")

if __name__ == "__main__":
    main()
