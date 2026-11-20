# Nami Logo

两道流动的波形代表消息和设备通信。深青底色 `#073F3C`，前景为薄荷青 `#5EEAD4` 和浅白 `#F0FDFA`。图形不含文字，在小尺寸和不同桌面裁切下保持辨识度。

- `nami.svg`：可缩放的彩色 Logo。
- `nami.png`：1024 × 1024 导出图。
- Android 原生资源：`../android/app/src/main/res/drawable/ic_launcher_*.xml`。
- Android 13 及以上提供单色主题图标。

在 Windows 使用 `powershell -NoProfile -File apps/android/branding/export-icons.ps1`，从 Android 矢量前景重新导出主 PNG 和五档启动图标。自适应图标由系统负责裁切，位图保留完整底色。
