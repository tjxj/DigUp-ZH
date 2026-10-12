"""Retired compatibility entry point. DigUp-ZH runs its bundled Qwen helper."""

import json
import sys


def main():
    message = (
        "旧版 Python worker 已停用。DigUp-ZH 使用内置 Qwen3-VL-Embedding-2B。"
        "请移除 DIGUP_WORKER_DIR，通过 DIGUP_MODELS 指定配套模型目录，"
        "然后使用 .build/release/digup worker。"
    )
    print(json.dumps({"ready": False, "error": message}, ensure_ascii=False), flush=True)
    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
