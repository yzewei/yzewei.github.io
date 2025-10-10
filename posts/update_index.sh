#!/bin/bash
# 自动生成 posts/index.md 索引页
# 使用说明：cd ~/yzewei.github.io/posts && ./update_index.sh

INDEX_FILE="index.md"

# 写入 front-matter 和标题
echo -e "---\ntitle: 所有文章索引\ndate: $(date '+%Y-%m-%d %H:%M:%S')\n---\n\n# 所有文章索引\n" > "$INDEX_FILE"

# 遍历所有 md 文件（排除 index.md 本身）
for f in *.md; do
    [[ "$f" == "$INDEX_FILE" ]] && continue
    title=$(basename "$f" .md)
    # 替换空格为 %20（网页链接安全）
    link=$(echo "$f" | sed 's/ /%20/g')
    echo "- [$title](./$link)" >> "$INDEX_FILE"
done

echo "✅ 已更新索引：$INDEX_FILE"

