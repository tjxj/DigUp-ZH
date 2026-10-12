# 旧 Python worker 已停用

DigUp-ZH 使用随应用提供的 Qwen3-VL-Embedding-2B 本地运行程序。旧版 Python 模型实现及其依赖清单已移除，避免误下载其他模型或混用不兼容的搜索索引。

`digup_worker.py` 仅保留为兼容提示：运行后明确说明迁移方式并退出，不导入第三方模型库、不下载模型，也不读取你的文件。

请移除 `DIGUP_WORKER_DIR` 环境变量；需要指定模型目录时，使用 `DIGUP_MODELS`。开发者可运行：

```sh
DIGUP_MODELS="$PWD/.models" .build/release/digup worker --text-only
```

正式安装包会自动使用包内配套模型。旧版源代码仍可从上游 DigUp 的版本记录查阅。
