#!/bin/bash

# 将新文件添加到 Xcode 项目的脚本
# 使用方法: ./add_files_to_xcode.sh

PROJECT_FILE="WallHaven.xcodeproj/project.pbxproj"

if [ ! -f "$PROJECT_FILE" ]; then
    echo "错误: 找不到项目文件 $PROJECT_FILE"
    exit 1
fi

echo "注意: 此脚本需要 Ruby 和 xcodeproj gem"
echo "安装方法: sudo gem install xcodeproj"
echo ""

# 检查是否安装了 xcodeproj
if ! command -v xcodeproj &> /dev/null; then
    echo "正在安装 xcodeproj gem..."
    gem install xcodeproj
fi

# 创建 Ruby 脚本来添加文件
cat > /tmp/add_files.rb << 'RUBY_SCRIPT'
require 'xcodeproj'

project_path = 'WallHaven.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'WallHaven' }
if target.nil?
  puts "错误: 找不到 WallHaven target"
  exit 1
end

# 定义新文件
new_files = [
  # Models
  { path: 'Models/ContentModels.swift', group: 'Models' },
  { path: 'Models/DataSourceRule.swift', group: 'Models' },
  # Services
  { path: 'Services/RuleLoader.swift', group: 'Services' },
  { path: 'Services/ContentService.swift', group: 'Services' },
  { path: 'Services/UserLibrary.swift', group: 'Services' },
  # Views
  { path: 'Views/AnimeContentView.swift', group: 'Views' },
  { path: 'Views/MyLibraryContentView.swift', group: 'Views' },
  { path: 'Views/SourceRulesSettingsView.swift', group: 'Views' },
  # Rules
  { path: 'Rules/wallhaven.json', group: 'Rules' },
  { path: 'Rules/gimy-example.json', group: 'Rules' },
]

# 查找或创建组
def find_or_create_group(project, group_name)
  group = project.main_group.find_subpath(group_name, false)
  if group.nil?
    group = project.main_group.new_group(group_name, group_name)
    puts "创建组: #{group_name}"
  else
    puts "使用现有组: #{group_name}"
  end
  group
end

# 添加文件
new_files.each do |file_info|
  group = find_or_create_group(project, file_info[:group])

  # 检查文件是否已存在
  existing_file = group.files.find { |f| f.path == file_info[:path] }
  if existing_file
    puts "文件已存在: #{file_info[:path]}"
    next
  end

  # 添加文件引用
  file_ref = group.new_file(file_info[:path])

  # 如果是 Swift 文件，添加到编译源
  if file_info[:path].end_with?('.swift')
    target.source_build_phase.add_file_reference(file_ref)
    puts "添加并编译: #{file_info[:path]}"
  else
    puts "添加资源: #{file_info[:path]}"
  end
end

# 保存项目
project.save
puts ""
puts "✅ 所有文件已添加到 Xcode 项目"
puts "请重新打开 Xcode 项目查看更改"
RUBY_SCRIPT

# 运行 Ruby 脚本
cd /Volumes/mac/CodeLibrary/Claude/WallHaven
ruby /tmp/add_files.rb
