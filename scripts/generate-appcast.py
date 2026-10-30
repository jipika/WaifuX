#!/usr/bin/env python3
"""生成 Sparkle appcast.xml —— 拆架构分发的单一事实来源。

ci.yml（push main 发版线）与 release.yml（tag / dispatch 线）都调用本脚本，
不再各自内联生成逻辑（曾因两处逻辑漂移踩过坑）。

appcast 结构（38.0.154 起）：
  item 1  default  channel：指向 universal 全量包 WaifuX.dmg（无 <sparkle:channel>，
                          对未声明 channel 的旧客户端恒可见；每次发版都产出）
  item 2  arm64    channel：WaifuX-arm64.dmg + <sparkle:hardwareRequirements>arm64</...>
  item 3  x86_64   channel：WaifuX-x86_64.dmg

用法：
  SPARKLE_PRIVATE_KEY=xxx python3 scripts/generate-appcast.py \
      --version 38.0.154 --changelog-file /tmp/changelog.txt

环境变量：
  SPARKLE_PRIVATE_KEY        Sparkle EdDSA 私钥；缺失时跳过签名（生成不带签名的 appcast 并警告）

行为（每次发版固定产出三个包：arm64 / x86_64 / universal）：
  - build/WaifuX-arm64.dmg / build/WaifuX-x86_64.dmg 必须存在，各自签名 → channel item
  - build/WaifuX.dmg 存在 → 签名 → default item（老 universal 客户端的升级通道，版本即当前版本），
    并把该 item 写入 Docs/appcast-default-item.xml 作为降级片段
  - build/WaifuX.dmg 缺失 → 降级复用 Docs/appcast-default-item.xml（若有），仅警告不阻断发版
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BUILD_DIR = ROOT / "build"
DEFAULT_DOCS_DIR = ROOT / "Docs"
REPO = "jipika/WaifuX"

ITEM_TEMPLATE = """  <item>
    <title>Version {version}</title>
    <sparkle:version>{version}</sparkle:version>
    <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
{extra}    <pubDate>{pub_date}</pubDate>
    <description><![CDATA[{desc}]]></description>
    <enclosure
      url="https://github.com/{repo}/releases/download/v{version}/{dmg}"
      type="application/octet-stream"
      length="{size}"
      sparkle:edSignature="{sig}"
    />
  </item>"""

RSS_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>WaifuX</title>
    <link>https://jipika.github.io/WaifuX/appcast.xml</link>
    <description>WaifuX Updates</description>
    <language>zh</language>
{items}
  </channel>
</rss>
"""


def log(message: str) -> None:
    print(message, flush=True)


def warn(message: str) -> None:
    print(f"⚠️  {message}", file=sys.stderr, flush=True)


def fail(message: str) -> None:
    raise SystemExit(f"❌ {message}")


def changelog_html(version: str, changelog: str) -> str:
    """把 changelog 文本渲染成 appcast 描述 HTML。

    渲染规则与 scripts/generate-appcast-changelog.py 共用同一份实现（`## 分组`
    渲染成 <h4>、`- 条目` 渲染成 <li>），避免两处逻辑漂移——历史上正是这个
    漂移导致手写分组标题在 appcast 里消失。
    """
    script = Path(__file__).with_name("generate-appcast-changelog.py")
    spec = importlib.util.spec_from_file_location("appcast_changelog", script)
    if spec is None or spec.loader is None:
        raise SystemExit(f"❌ 无法加载 {script}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.notes_to_html(changelog, version)


def find_sign_update(explicit: str | None) -> str | None:
    if explicit:
        return explicit if Path(explicit).is_file() else None
    from shutil import which

    return which("sign_update")


def sign_dmg(dmg: Path, private_key: str, sign_update: str) -> tuple[str, int]:
    """返回 (edSignature, 文件字节数)。"""
    result = subprocess.run(
        [sign_update, "-s", private_key, str(dmg)],
        capture_output=True,
        text=True,
    )
    output = (result.stdout or "") + (result.stderr or "")
    match = re.search(r'sparkle:edSignature="([^"]*)"', output)
    if result.returncode != 0 or not match:
        fail(f"sign_update 失败：{dmg}\n{output.strip()[:400]}")
    return match.group(1), dmg.stat().st_size


def build_item(
    *,
    version: str,
    pub_date: str,
    desc: str,
    dmg_name: str,
    size: int,
    sig: str,
    extra: str = "",
) -> str:
    return ITEM_TEMPLATE.format(
        version=version,
        pub_date=pub_date,
        desc=desc,
        dmg=dmg_name,
        size=size,
        sig=sig,
        extra=extra,
        repo=REPO,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True, help="发布版本号，例如 38.0.154")
    parser.add_argument("--changelog", default="", help="变更日志文本（- 开头的行会渲染成列表）")
    parser.add_argument("--changelog-file", type=Path, help="从文件读取变更日志")
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    parser.add_argument("--docs-dir", type=Path, default=DEFAULT_DOCS_DIR)
    parser.add_argument("--sign-update", help="sign_update 可执行文件路径（默认从 PATH 查找）")
    parser.add_argument("--no-sign", action="store_true", help="跳过签名（本地调试用）")
    parser.add_argument("--pub-date", help="覆盖 pubDate（RFC 822）")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    version = args.version.strip()
    if not re.fullmatch(r"\d+(?:\.\d+)+", version):
        fail(f"版本号格式不合法：{version!r}")

    build_dir: Path = args.build_dir
    docs_dir: Path = args.docs_dir
    docs_dir.mkdir(parents=True, exist_ok=True)

    changelog = args.changelog
    if args.changelog_file is not None:
        changelog = args.changelog_file.read_text(encoding="utf-8")
    desc = changelog_html(version, changelog)

    pub_date = args.pub_date or datetime.now(timezone(timedelta(hours=8))).strftime("%a, %d %b %Y %H:%M:%S %z")

    private_key = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    sign_update = find_sign_update(args.sign_update)
    signing = bool(private_key) and bool(sign_update) and not args.no_sign
    if not signing:
        warn("未签名（缺少 SPARKLE_PRIVATE_KEY 或 sign_update）；Sparkle 客户端会拒绝该 appcast")

    def sign_if_possible(dmg: Path) -> tuple[str, int]:
        if signing:
            return sign_dmg(dmg, private_key, sign_update)  # type: ignore[arg-type]
        return "", dmg.stat().st_size

    # ---- arm64 / x86_64 channel item ----
    arm64_dmg = build_dir / "WaifuX-arm64.dmg"
    x86_dmg = build_dir / "WaifuX-x86_64.dmg"
    for dmg in (arm64_dmg, x86_dmg):
        if not dmg.is_file():
            fail(f"缺少 {dmg}（先运行 scripts/package.sh 打包对应架构）")

    sig_arm, size_arm = sign_if_possible(arm64_dmg)
    sig_x86, size_x86 = sign_if_possible(x86_dmg)
    log(f"✅ arm64 DMG 已处理 ({size_arm} bytes)")
    log(f"✅ x86_64 DMG 已处理 ({size_x86} bytes)")

    arch_items = [
        build_item(
            version=version, pub_date=pub_date, desc=desc,
            dmg_name="WaifuX-arm64.dmg", size=size_arm, sig=sig_arm,
            extra="    <sparkle:channel>arm64</sparkle:channel>\n    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n",
        ),
        build_item(
            version=version, pub_date=pub_date, desc=desc,
            dmg_name="WaifuX-x86_64.dmg", size=size_x86, sig=sig_x86,
            extra="    <sparkle:channel>x86_64</sparkle:channel>\n",
        ),
    ]

    # ---- default item（旧 universal 客户端的升级通道）----
    # 常规发版每次都会构建 universal 包（scripts/package.sh WAIFUX_ARCH=universal），
    # 因此 default item 每次都取当前版本 —— 老客户端一步直达最新版。
    # 若某次没有构建 universal（build/WaifuX.dmg 缺失），降级复用历史片段，不阻断发版。
    universal_dmg = build_dir / "WaifuX.dmg"
    default_item_file = docs_dir / "appcast-default-item.xml"
    default_item = ""

    if universal_dmg.is_file():
        sig_uni, size_uni = sign_if_possible(universal_dmg)
        default_item = build_item(
            version=version, pub_date=pub_date,
            desc=f"<p>WaifuX {version}（universal 版本，同时适用于 Apple Silicon 与 Intel）</p>",
            dmg_name="WaifuX.dmg", size=size_uni, sig=sig_uni,
        )
        # 固化为 release 资产，供「某次未构建 universal」时降级读取
        default_item_file.write_text(default_item + "\n", encoding="utf-8")
        log(f"✅ universal 包 → default item ({size_uni} bytes)，片段已写入 {default_item_file}")
    elif default_item_file.is_file():
        default_item = default_item_file.read_text(encoding="utf-8").strip()
        warn(
            f"本次未构建 universal 包，default item 降级复用片段：{default_item_file}"
            "（老客户端会升级到该片段对应的版本，之后仍可继续升级）"
        )
    else:
        warn(
            "无 default channel item（既无 build/WaifuX.dmg 也没有历史片段）："
            "旧版 universal 客户端收不到本次更新，按架构分发的客户端不受影响"
        )

    items = ([default_item] if default_item else []) + arch_items
    appcast = RSS_TEMPLATE.format(items="\n".join(items))
    appcast_file = docs_dir / "appcast.xml"
    appcast_file.write_text(appcast, encoding="utf-8")
    log(f"✅ 已生成 {appcast_file}（{len(items)} 个 item）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
