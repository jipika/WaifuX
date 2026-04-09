#!/bin/bash
#
# 自动更新 GitHub Hosts 脚本
# 来源: https://github.com/oopsunix/hosts
#

set -e

HOSTS_FILE="/etc/hosts"
BACKUP_DIR="$HOME/.hosts_backup"
GITHUB_HOSTS_URL="https://raw.githubusercontent.com/oopsunix/hosts/main/hosts_github"
TEMP_FILE=$(mktemp)

echo "🔄 正在下载最新的 GitHub Hosts..."

# 下载最新的 hosts
if ! curl -sL --connect-timeout 10 "$GITHUB_HOSTS_URL" -o "$TEMP_FILE"; then
    echo "❌ 下载失败，请检查网络连接"
    rm -f "$TEMP_FILE"
    exit 1
fi

# 验证下载内容
if [ ! -s "$TEMP_FILE" ]; then
    echo "❌ 下载内容为空"
    rm -f "$TEMP_FILE"
    exit 1
fi

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 备份当前 hosts
echo "📦 备份当前 hosts..."
cp "$HOSTS_FILE" "$BACKUP_DIR/hosts.backup.$(date +%Y%m%d_%H%M%S)"

# 清理旧备份（保留最近 10 个）
ls -t "$BACKUP_DIR"/hosts.backup.* 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true

# 移除旧的 GitHub hosts 配置（如果存在）
echo "🧹 清理旧的 GitHub Hosts 配置..."
sudo sed -i '' '/# GitHub Hosts Start/,/# GitHub Hosts End/d' "$HOSTS_FILE" 2>/dev/null || \
sudo sed -i '/# GitHub Hosts Start/,/# GitHub Hosts End/d' "$HOSTS_FILE" 2>/dev/null || true

# 添加新的 GitHub hosts
echo "✅ 应用新的 GitHub Hosts..."
echo "" | sudo tee -a "$HOSTS_FILE" > /dev/null
cat "$TEMP_FILE" | sudo tee -a "$HOSTS_FILE" > /dev/null

# 刷新 DNS 缓存
echo "🔄 刷新 DNS 缓存..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sudo dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    echo "✅ macOS DNS 缓存已刷新"
else
    # Linux
    sudo systemd-resolve --flush-caches 2>/dev/null || \
    sudo service network-manager restart 2>/dev/null || \
    sudo /etc/init.d/dns-clean start 2>/dev/null || true
    echo "✅ Linux DNS 缓存已刷新"
fi

# 清理临时文件
rm -f "$TEMP_FILE"

# 测试 GitHub 连接
echo ""
echo "🧪 测试 GitHub 连接..."
if curl -sI --connect-timeout 5 "https://github.com" > /dev/null 2>&1; then
    echo "✅ GitHub 连接正常！"
else
    echo "⚠️  GitHub 连接测试失败，请检查网络"
fi

echo ""
echo "🎉 GitHub Hosts 更新完成！"
echo "📍 Hosts 文件: $HOSTS_FILE"
echo "📦 备份目录: $BACKUP_DIR"
