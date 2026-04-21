#!/usr/bin/env python3
"""
把 Resources/ 根目录下的 dylib 移到 Resources/lib/ 子目录，
并统一修改依赖路径为 @loader_path/lib/xxx
"""
import os
import subprocess
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
LIB = os.path.join(RES, "lib")

def get_dylibs_in_res():
    files = []
    for name in os.listdir(RES):
        path = os.path.join(RES, name)
        if os.path.isfile(path) and name.endswith(".dylib"):
            files.append(name)
    return files

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

def change_install_name(dylib_path: str, old_name: str, new_name: str):
    subprocess.run(
        ["install_name_tool", "-change", old_name, new_name, dylib_path],
        capture_output=True, check=True
    )

def set_id_name(dylib_path: str, new_id: str):
    subprocess.run(
        ["install_name_tool", "-id", new_id, dylib_path],
        capture_output=True, check=True
    )

def main():
    os.makedirs(LIB, exist_ok=True)

    dylibs = get_dylibs_in_res()
    if not dylibs:
        print("No dylibs found in Resources/")
        return

    print(f"Moving {len(dylibs)} dylibs to Resources/lib/...")

    # 1. 移动所有 dylib 到 lib/
    for name in dylibs:
        src = os.path.join(RES, name)
        dst = os.path.join(LIB, name)
        if os.path.islink(src):
            link_target = os.readlink(src)
            if os.path.isabs(link_target):
                real_target = os.path.realpath(src)
                link_target = os.path.basename(real_target)
            if os.path.exists(dst):
                os.remove(dst)
            os.symlink(link_target, dst)
            os.remove(src)
        else:
            shutil.move(src, dst)
            os.chmod(dst, 0o755)
        print(f"  Moved: {name}")

    # 2. 修改所有 dylib 的依赖路径
    print("\nUpdating install names...")
    for name in dylibs:
        path = os.path.join(LIB, name)
        if os.path.islink(path):
            continue

        # 修改自身 id
        current_id = subprocess.run(
            ["otool", "-D", path], capture_output=True, text=True, check=True
        ).stdout.strip().split("\n")[1].strip() if len(subprocess.run(
            ["otool", "-D", path], capture_output=True, text=True, check=True
        ).stdout.strip().split("\n")) >= 2 else None

        if current_id:
            new_id = f"@loader_path/lib/{name}"
            if current_id != new_id:
                set_id_name(path, new_id)
                print(f"  {name}: id -> {new_id}")

        # 修改依赖
        deps = get_dependencies(path)
        for dep in deps:
            if dep.startswith("@loader_path/lib/"):
                continue
            if dep.startswith("@loader_path/"):
                basename = dep[len("@loader_path/"):]
                new_dep = f"@loader_path/lib/{basename}"
                change_install_name(path, dep, new_dep)
                print(f"  {name}: {dep} -> {new_dep}")
            elif "/opt/homebrew" in dep or "/usr/local" in dep:
                basename = os.path.basename(dep)
                new_dep = f"@loader_path/lib/{basename}"
                change_install_name(path, dep, new_dep)
                print(f"  {name}: {dep} -> {new_dep}")

    # 3. 重新签名
    print("\nRe-signing...")
    for name in dylibs:
        path = os.path.join(LIB, name)
        if os.path.islink(path):
            continue
        subprocess.run(
            ["codesign", "--force", "-s", "-", path],
            capture_output=True, check=False
        )

    print("\nDone! All dylibs are now in Resources/lib/")

if __name__ == "__main__":
    main()
