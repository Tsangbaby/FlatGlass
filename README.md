# FlatGlass 1.8.4 —— 源码还原工程

由 `local.lumid.flatglass_1.8.4_iphoneos-arm64.deb` 逆向还原。
所有 4 个二进制的本地符号完好，因此**函数名、类名、ivar、常量、字符串都是"原名"**，
可以直接和反汇编逐条对照。

## 目录

```
FlatGlass/
├── Makefile                      聚合 4 个子工程（THEOS_PACKAGE_SCHEME=rootless）
├── control
├── layout/                       资源 + 安装脚本（原样取自 deb）
│   ├── DEBIAN/{postinst,prerm}
│   └── Library/{MobileSubstrate,LaunchDaemons,PreferenceLoader,PreferenceBundles}
├── FlatGlassIconServices/        ★ 核心渲染器（注入 iconservicesagent）
│   ├── FGInternal.h              类型 / 全局 / 常量 / 函数声明
│   ├── FlatGlassIconServices.m   钩子层：模式、缓存失效、两个替换实现
│   ├── FGCatalog.m               分层图标数据模型 + CUICatalog 索引 + 资源块解析
│   ├── FGDraw.m                  drawNode / drawFill / drawElement
│   ├── FGCreate.m                NGCreateFlatIcon（Mode 0 / 3 全链路）
│   ├── FGGlass.m                 NGCreateGlassIcon / Rimmed / Glassed（v1 近似）
│   └── FGIconGlare.c             squircle 形状 / 模糊 / EDT / 描边 / 高光
├── FlatGlassRefresh/             SpringBoard 侧：清缓存 + 分批重载 + 重绘
├── FlatGlassPrefs/               设置面板
├── flatglass/                    launchd 守护进程（模式广播）
└── reverse-reference/            逐指令还原稿（权威参考，非编译单元）
    ├── A_draw.c    drawFill/drawElement/keyValue/rawData/byName/createColor/drawContents
    ├── B_glass.c   NGCreateGlassIcon/Rimmed/Glassed 全部常量与分支
    ├── C_catalog.c findStack/indexFor/HasLayeredPrimaryResource
    ├── D_iconglare.c IGDrawGroup/edt/gaussianBlur/IGCreateIconShape/IGDrawOutline…
    └── E_cli.m     flatglass CLI（含 Assets.car / BOMStore 解析器）
```

## 编译

```bash
export THEOS=/opt/theos
make package FINALPACKAGE=1
```

需要 iOS 15+ SDK。产物：`packages/local.lumid.flatglass_1.8.4_iphoneos-arm64.deb`。

安装后 `killall -9 iconservicesagent SpringBoard`（或 respring）。

## 各模块保真度

| 模块 | 保真度 | 说明 |
|---|---|---|
| `FlatGlassRefresh.m` | **逐指令精确** | 45 个符号全部对上，含所有 runtime 形态校验 |
| `FGSettingsListController.m` | **逐指令精确** | 4 个方法全部对上 |
| `FlatGlassIconServices.m`（钩子/模式/缓存） | **逐指令精确** | 含 `exit(0)` 重启语义 |
| `FGCatalog.m` | **高** | 容器布局、key/keyList 语义、颜色/渐变/图像块、SVG 转发均按原样；`indexFor` 里两处 KVC 取裸指针的写法按"响应 bytes 就用 bytes，否则当裸指针"做了兼容 |
| `FGDraw.m` | **高** | drawNode/drawFill/drawElement 全部分支、渐变亮度派生公式（0.20/0.25/0.30/-0.10 四档）均按原样 |
| `FGCreate.m` | **逐指令精确** | 含 tintable 的 Rec.709 灰度化 |
| `FGIconGlare.c` | 中（形状精确，其余近似） | `FGIconShape` 的四段贝塞尔常量逐个实读；模糊/描边/高光为结构化近似，见文件末尾 TODO |
| `FGGlass.m` | **v1 近似** | 入口、`gGlassNoEdge` 语义正确；`IGDrawGroup` 多通道玻璃合成未编译化 |
| `flatglass/main.m` | 高（核心路径） | `--watch` / `--disable` / 模式广播 / SnowBoard 注销均精确；`--preview-scan`、`--gloss-icon` 未包含 |

## 运行时协议备忘（来自 CLI 逆向）

- `state = (Mode >= 4) ? 1 : Mode + 1`；`--disable` 直接写 state **3**（= Mode 2 / Off）。
- `Apps.plist`：`{[bundleid]: {key, rendered(BOOL), nativeHighlight(int)}}`，
  `key = "3|<appDir>|<iconName>|<CFBundleVersion>|<mtime>|<size>"`，兼容首字符换 `2` 的旧键。
- 子进程渲染协议：`flatglass <Assets.car> <iconName> <out.png>`（argc==4），
  退出码 `0` = 已渲染，`2` = init 失败（静默跳过），其它 = unsupported，usage 错误 `64`。
- `--watch` 只从 SnowBoard 的 `ActiveMenuItems` 里**剔除**自己的三个主题目录，从不主动添加。

## 下一步（若要 100% 对齐观感）

1. 把 `reverse-reference/B_glass.c` 的 `NGCreateGlassIcon` 与 `Reverse-reference/D_iconglare.c`
   的 `IGDrawGroup` / `IGDrawChicletHighlights` / `IGDrawOutline` 编译化，替换 `FGGlass.m` 与
   `FGIconGlare.c` 里的近似实现。
2. 三处占位系数（`FGIconGlare.c` 末尾）需要在设备上按 `IG_STEPS` 各通道截图对比后校正。
3. `FGCatalog.m` 里 `indexFor` 的 `keyFormat` / 枚举 key 是裸指针还是 `NSData`，
   建议在真机上打日志确认（两条分支都写好了，切一下即可）。

## 已知缺陷（原版就有，未擅自修复）

见 `../FlatGlass_REVERSE_ENGINEERING.md` §1.2 与 §8：Mode 1 / Mode 3 的标签与行为互换，
且 iOS 26 分层图标下 Mode 3 退化成 Mode 0。
