# DigUp-ZH 图标：寻文

深青色底板上，一枚米白色放大镜圈住“文”字，右上角是一枚朱红“中”字小印章。图形使用路径绘制，不依赖字体，也不含外部图片。

| 文件 | 用途 |
| --- | --- |
| `appicon.svg` | 1024 × 1024 主图标，可编辑的原始文件 |
| `appicon-small.svg` | 16、32 像素简化版：加粗主体、去掉小印章里的笔画 |
| `appicon-1024.png`、`appicon-256.png`、`appicon-32.png` | 可直接预览和复用的图片 |
| `../AppIcon.icns` | macOS 应用图标，包含 16 到 1024 像素的 10 种图像表示 |
| `AppIcon.icon/` | 供支持 Icon Composer 的构建环境使用的分层版本 |
| `menubar.svg` | 单色菜单栏图标参考；应用中的菜单栏图案由界面代码绘制 |

颜色：深青 `#103F43`、米白 `#F5EBD6`、朱红 `#D9684F`。

在项目根目录运行：

```sh
swift scripts/make-zh-icon.swift
```

脚本用 macOS 自带的图形工具渲染 SVG，生成 PNG 和 `Resources/AppIcon.icns`，无需下载图片或安装字体。临时文件会在完成后清理。

DigUp-ZH 图标为本项目重新设计，按仓库的 MIT 许可证提供。保留原有可编辑图标目录结构，方便继续修改。
