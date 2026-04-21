#!/usr/bin/env python3
"""
递归复制 Homebrew dylib 依赖到 App Bundle Resources，并修改 install names。
用法: python3 scripts/bundle-dylibs.py <source_dylib> <dest_dir>
"""
import subprocess
import sys
import os
import shutil
from pathlib import Path

BREW_PREFIX = "/opt/homebrew"


def get_dependencies(dylib_path: str) -> list:
    """获取 dylib 的所有依赖路径（排除系统库和自身）"""
    result = subprocess.run(
        ["otool", "-L", dylib_path],
        capture_output=True, text=True, check=True
    )
    deps = []
    for line in result.stdout.strip().split("\n")[1:]:  # 跳过第一行（自身）
        line = line.strip()
        if not line:
            continue
        # 格式: "\t/path/to/lib.dylib (compatibility version ...)"
        path = line.split(" ")[0]
        # 排除系统库
        if path.startswith("/usr/lib/") or path.startswith("/System/"):
            continue
        # 排除自身
        if path == dylib_path:
            continue
        # 只处理 brew 相关的库
        if BREW_PREFIX in path or path.startswith("@rpath/") or path.startswith("@loader_path"):
            deps.append(path)
    return deps


def resolve_symlink(path: str) -> str:
    """解析符号链接到实际文件"""
    p = Path(path)
    if p.is_symlink():
        real = os.path.realpath(path)
        if os.path.exists(real):
            return real
    return path


def copy_with_symlinks(source_path: str, dest_dir: str):
    """复制文件，保留符号链接结构"""
    basename = os.path.basename(source_path)
    dest_path = os.path.join(dest_dir, basename)

    # 如果源是符号链接
    if os.path.islink(source_path):
        # 获取链接目标
        link_target = os.readlink(source_path)
        # 如果目标是相对路径，保持；如果是绝对路径，转换为相对路径
        if os.path.isabs(link_target):
            # 转换为相对于 dest_dir 的路径
            real_target = os.path.realpath(source_path)
            target_basename = os.path.basename(real_target)
            link_target = target_basename

        # 创建符号链接
        if os.path.exists(dest_path):
            os.remove(dest_path)
        os.symlink(link_target, dest_path)
        return

    # 复制实际文件
    if not os.path.exists(dest_path):
        shutil.copy2(source_path, dest_path)
        os.chmod(dest_path, 0o755)


def collect_all_dependencies(start_dylib: str, collected: set = None) -> set:
    """递归收集所有依赖的 dylib"""
    if collected is None:
        collected = set()

    real_path = resolve_symlink(start_dylib)
    if real_path in collected:
        return collected

    collected.add(real_path)

    for dep in get_dependencies(real_path):
        if dep.startswith("@rpath/") or dep.startswith("@loader_path"):
            # 相对路径，尝试在同级目录查找
            base_dir = os.path.dirname(real_path)
            lib_name = dep.split("/")[-1]
            candidate = os.path.join(base_dir, lib_name)
            if os.path.exists(candidate):
                collect_all_dependencies(candidate, collected)
            continue

        if dep.startswith(BREW_PREFIX):
            real_dep = resolve_symlink(dep)
            if os.path.exists(real_dep):
                collect_all_dependencies(real_dep, collected)

    return collected


def get_install_name(dylib_path: str) -> str:
    """获取 dylib 的 install name（第一行）"""
    result = subprocess.run(
        ["otool", "-D", dylib_path],
        capture_output=True, text=True, check=True
    )
    lines = result.stdout.strip().split("\n")
    if len(lines) >= 2:
        return lines[1].strip()
    return None


def change_install_name(dylib_path: str, old_name: str, new_name: str):
    """修改 dylib 的依赖路径"""
    cmd = ["install_name_tool", "-change", old_name, new_name, dylib_path]
    subprocess.run(cmd, capture_output=True, check=True)


def set_id_name(dylib_path: str, new_id: str):
    """修改 dylib 自身的 install name（id）"""
    cmd = ["install_name_tool", "-id", new_id, dylib_path]
    subprocess.run(cmd, capture_output=True, check=True)


def add_rpath(dylib_path: str, rpath: str):
    """添加 rpath"""
    cmd = ["install_name_tool", "-add_rpath", rpath, dylib_path]
    result = subprocess.run(cmd, capture_output=True)
    # 如果 rpath 已存在，会报错，忽略
    if result.returncode != 0 and b"would duplicate" not in result.stderr:
        print(f"  Warning: add_rpath failed: {result.stderr.decode().strip()}")


def process_dylib(source_path: str, dest_dir: str, processed: set = None):
    """处理单个 dylib：复制并修改依赖路径"""
    if processed is None:
        processed = set()

    real_source = resolve_symlink(source_path)
    if real_source in processed:
        return
    processed.add(real_source)

    basename = os.path.basename(real_source)
    dest_path = os.path.join(dest_dir, basename)

    # 复制文件（保留符号链接结构）
    if not os.path.exists(dest_path) or os.path.islink(source_path):
        print(f"  Copy: {basename}")
        # 如果源是符号链接，复制符号链接；否则复制实际文件
        if os.path.islink(source_path):
            copy_with_symlinks(source_path, dest_dir)
        else:
            copy_with_symlinks(real_source, dest_dir)
        if os.path.exists(dest_path) and not os.path.islink(dest_path):
            # 确保可写（用于 install_name_tool）
            os.chmod(dest_path, 0o755)

    # 如果原始路径是符号链接，确保目标目录中也有对应的符号链接
    if os.path.islink(source_path):
        link_target = os.readlink(source_path)
        if os.path.isabs(link_target):
            real_target = os.path.realpath(source_path)
            target_basename = os.path.basename(real_target)
            # 创建相对符号链接
            if not os.path.exists(dest_path):
                os.symlink(target_basename, dest_path)

    # 修改自身的 id
    current_id = get_install_name(dest_path)
    if current_id:
        new_id = f"@loader_path/{basename}"
        if current_id != new_id:
            print(f"    Set id: {new_id}")
            set_id_name(dest_path, new_id)

    # 修改依赖路径
    deps = get_dependencies(real_source)
    for dep in deps:
        if dep.startswith("@rpath/") or dep.startswith("@loader_path"):
            # 已经是相对路径，跳过
            continue

        dep_basename = os.path.basename(dep)
        new_dep = f"@loader_path/{dep_basename}"

        # 在目标目录中查找依赖
        dep_in_dest = os.path.join(dest_dir, dep_basename)
        if os.path.exists(dep_in_dest):
            print(f"    Change: {dep} -> {new_dep}")
            change_install_name(dest_path, dep, new_dep)
        else:
            # 尝试解析并复制依赖
            real_dep = resolve_symlink(dep)
            if os.path.exists(real_dep):
                process_dylib(real_dep, dest_dir, processed)
                # 如果复制后 dep_basename 仍然不存在（因为实际文件名不同），
                # 创建一个符号链接
                if not os.path.exists(dep_in_dest):
                    real_basename = os.path.basename(real_dep)
                    real_in_dest = os.path.join(dest_dir, real_basename)
                    if os.path.exists(real_in_dest):
                        os.symlink(real_basename, dep_in_dest)
                if os.path.exists(dep_in_dest):
                    print(f"    Change: {dep} -> {new_dep}")
                    change_install_name(dest_path, dep, new_dep)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <source_dylib> <dest_dir>")
        sys.exit(1)

    source = sys.argv[1]
    dest = sys.argv[2]

    if not os.path.exists(source):
        print(f"Error: {source} not found")
        sys.exit(1)

    os.makedirs(dest, exist_ok=True)

    print(f"Processing: {source}")
    print(f"Destination: {dest}")
    print()

    # 先收集所有依赖
    print("Collecting dependencies...")
    deps = collect_all_dependencies(source)
    print(f"Found {len(deps)} dependencies")
    print()

    # 处理主 dylib 和所有依赖
    processed = set()
    print("Bundling...")
    process_dylib(source, dest, processed)

    # 也处理所有收集到的依赖
    for dep in deps:
        if dep != resolve_symlink(source):
            process_dylib(dep, dest, processed)

    print()
    print("Done!")


if __name__ == "__main__":
    main()
