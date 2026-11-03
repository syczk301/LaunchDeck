# LaunchDeck

A native macOS application launcher built with Swift and AppKit. 中文应用启动台，支持搜索、拖拽整理和自定义应用列表。

## 功能

- 全屏启动台、毛玻璃背景、连续滑动翻页与图标悬停动画。
- 中文、英文、拼音及首字母搜索。
- 全部应用 / 仅显示已选应用，在网格中直接勾选。
- 拖动排序、创建文件夹、文件夹内排序与改名，重启保留布局。
- 新安装的软件自动加入已选列表末尾；手动取消选择后不会再次自动加入。
- 可配置网格、快捷键、触发角、滚动灵敏度、Dock 显示及登录启动。
- 登录启动时后台驻留，不主动弹出界面；手动点击 Dock 再打开。

## 下载与安装

前往 [Releases](https://github.com/syczk301/LaunchDeck/releases/latest) 下载 DMG，将 `LaunchDeck.app` 拖入 Applications。更新前先退出旧版。

- Apple Silicon Mac，macOS 13 或更新版本。
- 当前安装包使用本地 ad-hoc 签名，**未经过 Apple Developer ID 公证**。
- 旧版 macOS 的兼容性以及实际注销后的登录启动行为，尚未完成全面实机验证。

## 使用

默认快捷键为 **Option + 空格**。按 Esc 关闭启动台，点击圆点、滚动或拖动空白处翻页。

清空搜索后可拖动图标排序。在另一个图标中心停留约 0.6 秒后松开，可创建或加入文件夹。文件夹内拖到返回按钮可移出应用；解散文件夹不会卸载软件。不支持嵌套文件夹。

新应用在下次扫描时自动加入已选列表。启动时、打开启动台时按需扫描，运行中约每分钟检查，也可从菜单栏手动刷新。升级后的首次扫描只记录现有应用，不重新勾选之前隐藏的软件。

## 本地数据

配置保存在 `~/Library/Application Support/LaunchDeck/preferences.json`，包含应用选择、顺序和文件夹。替换应用包不会清空这些数据。

应用不上传应用列表，不读取或修改 FolderX 配置。应用图标在运行时从本机读取，仓库不附带其他软件的图标资源。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools 和 Python 3，无第三方包依赖。

```bash
git clone https://github.com/syczk301/LaunchDeck.git
cd LaunchDeck
bash build.sh
```

构建结果为 `LaunchDeck.app`。构建脚本会执行启动类型识别、搜索、分页、应用选择、自动加入、排序、文件夹及配置序列化检查。

生成 DMG：

```bash
bash package-dmg.sh
```

安装包输出到 `dist/`，脚本会校验签名和磁盘映像。

## 项目说明

LaunchDeck 是参照 FolderX 启动台交互独立实现的项目，与 FolderX 无隶属关系。仅实现应用启动台，不包含 Finder 扩展、文件管理或局域网共享。动画与背景不保证与原版完全一致。

## License

[MIT](LICENSE)
