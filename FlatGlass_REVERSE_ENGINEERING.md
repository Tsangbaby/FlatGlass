# FlatGlass 1.8.4 深度逆向分析报告

> 对象：`local.lumid.flatglass_1.8.4_iphoneos-arm64.deb`（562,346 字节）
> 分析日期：2026-11-27
> 方法：Mach-O / chained-fixups 静态解析 + capstone 反汇编 + Swift/ObjC 元数据还原
> 结论可信度：**架构、hook、字符串、常量、数据格式 = 已确证**；绘制管线的逐像素细节 = **高保真还原，个别数值待设备验证**（文中标注）

---

## 0. 三十秒结论

FlatGlass 不是传统 Logos tweak，而是 **4 个独立二进制协同**的系统：

| 组件 | 安装路径 | 宿主进程 | 职责 |
|---|---|---|---|
| `FlatGlassIconServices.dylib` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` | `iconservicesagent` | **真正的渲染器**：拦截 `-imageForSize:scale:`，用系统 CUICatalog 里的分层 `.icon` 资源自己重画一遍图标 |
| `FlatGlassRefresh.dylib` | 同上 | `SpringBoard` | 渲染完成后清缓存 + 分批 `reloadIconImage` + 重绘可见 `SBIconImageView` |
| `flatglass`（CLI） | `/var/jb/usr/libexec/flatglass` | launchd daemon（`--watch`） | 模式广播、SnowBoard 主题同步、离线批量重渲染（`--preview-scan`）、`--disable` 清理 |
| `FlatGlassPrefs.bundle` | `/var/jb/Library/PreferenceBundles/` | Settings | 4 选项 UI，写 plist + 发 Darwin 通知 |

**所有 4 个二进制的本地符号都完好**（109 / 45 / 128 / 5 个具名函数），这是本次能高保真还原的关键。

**核心机制一句话**：Apple 在 iOS 26 把主屏图标换成了「Icon Composer 分层资源」(`.icon` → CUICatalog → `iconstack`)，系统用其中的 `effects` 段把高光/玻璃质感烘进渲染结果。FlatGlass 的做法是**绕开系统的 effects 段**，只取 `layers` 段自己用 CoreGraphics 重画，再按模式决定是否叠加自己实现的「玻璃高光」（高斯模糊 + 距离变换 + squircle 描边）。

---

## 1. 模式（Mode）体系 —— 注意：**1.8.4 的标签与行为是错位的**

### 1.1 三处存储

| 位置 | 形式 | 写入者 | 读取者 |
|---|---|---|---|
| `/var/mobile/Library/Preferences/local.lumid.flatglass.plist` `Mode` | 整数 0/1/2/3 | 设置面板 | CLI |
| Darwin notify `local.lumid.flatglass.iconservices-mode` 的 state | **`state = Mode + 1`**（1..4） | CLI `--watch` | 两个 dylib |
| `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache/.flatglass-mode` | 文本 `1:<Mode>` | IconServices 插件 | 同上（用来判断缓存是否已按当前模式重建过） |

`state = Mode + 1` 的原因：notify state 默认是 0，用 +1 才能区分「从未设置过」和「Mode 0」。

### 1.2 值 → 行为（实测自反汇编）

| Mode | plist 标签 | ComposedImage 路径（老式图标） | ResourceImage 路径（iOS 26 分层图标） |
|---|---|---|---|
| 0 | Remove Highlights | 直接透传原图 | `NGCreateFlatIcon` → 只画 layers，丢掉 effects |
| 1 | Edge and Artwork | `NGCreateRimmedImage`（只有描边） | `NGCreateGlassIcon` + `gGlassNoEdge=1`（**跳过 Chiclet 高光，只留描边**） |
| 2 | Off | 直接透传原图 | 直接透传原图 |
| 3 | Edge Only | `NGCreateGlassedImage`（完整玻璃：高光+描边） | `NGCreateFlatIcon`（同 Mode 0） |

> ⚠️ **这是 1.8.4 的一个真实缺陷**：标签写「Edge and Artwork = 1 / Edge Only = 3」，
> 但两条渲染路径都把 **1 当作"只有边"、把 3 当作"边+artwork"**（老式图标），
> 而 iOS 26 分层图标下 **3 退化成了 Mode 0**（完全无高光）。
> 也就是说：iOS 26 上「Edge Only」实际不生效，「Edge and Artwork」只出边。
> 还原工程**保持了与原版完全一致的行为**（不擅自"修好"），修复建议见 §8。

### 1.3 缓存失效与重启链路（关键，容易踩坑）

```
设置面板写 plist → notify_post("...settings-changed")
   └→ flatglass --watch 收到 → 读 Mode → notify_set_state(mode+1) + notify_post("...iconservices-mode")
        ├→ iconservicesagent 插件收到 → InvalidateCache(YES)
        │     ├ 比较 .flatglass-mode 内容与 "1:<mode>"
        │     ├ 不同 → 删除 IconsCache 目录下除标记文件外的全部条目
        │     ├ 写回标记文件
        │     └ 写成功 → exit(0)  ← 主动自杀，让 launchd 拉起一个干净的 agent
        └→ SpringBoard 插件收到 → 等 2s → 清图标缓存 → 每批 4 个 reloadIconImage（批间 0.4s）
                                     → performWithoutAnimation 里重绘所有可见 SBIconImageView
```

`exit(0)` 这一步是整个设计的关键：iconservicesagent 的图标缓存是进程内的，只有重启进程才会真正重读 `.icon` 资源。维护时如果去掉它，会出现"改了模式但图标不变"。

---

## 2. FlatGlassIconServices.dylib —— 渲染器

### 2.1 注入与打补丁

`__attribute__((constructor))` → `StartFlatGlassIconServices`（0x4000）：

```c
if (![processName isEqualToString:@"iconservicesagent"]) return;

Class IFImage            = objc_getClass("IFImage");
Class ISiOSAppRecipe     = objc_getClass("ISiOSAppRecipe");
Class ISAssetCatalogResource = objc_getClass("ISAssetCatalogResource");
Class ISCompositor       = objc_getClass("ISCompositor");

Method mRes = class_getInstanceMethod(ISAssetCatalogResource, @selector(imageForSize:scale:));
Method mCmp = class_getInstanceMethod(ISCompositor,           @selector(imageForSize:scale:));

// 兼容性门禁：签名必须完全匹配，否则整块不装
BOOL okRes = IsImageRenderer(mRes)
          && [ISAssetCatalogResource instancesRespondToSelector:@selector(catalog)]
          && [ISAssetCatalogResource instancesRespondToSelector:@selector(imageName)]
          && [IFImage instancesRespondToSelector:@selector(initWithCGImage:scale:)];
BOOL okCmp = ISiOSAppRecipe && IsImageRenderer(mCmp);

if (!okRes && !okCmp) { NSLog(@"FlatGlass: compatible IconServices methods were not found."); return; }

notify_register_dispatch("local.lumid.flatglass.iconservices-mode", ...,
                         dispatch_get_main_queue(), ^{ InvalidateCache(YES); });

if (okRes) { OriginalResourceImage = method_getImplementation(mRes);
             class_replaceMethod(ISAssetCatalogResource, @selector(imageForSize:scale:), ResourceImage, types); }
if (okCmp) { OriginalComposedImage = method_getImplementation(mCmp);
             class_replaceMethod(ISCompositor, @selector(imageForSize:scale:), ComposedImage, types); }

InvalidateCache(NO);
```

`IsImageRenderer(Method)`（0x4224）用运行时类型串做严格校验，这是全项目最保守也最重要的兼容层：

```
method_getNumberOfArguments(m) == 4        // self, _cmd, CGSize, CGFloat
returnType[0] == '@'
argumentType(2) == "{CGSize=dd}"           // 32 位比较：0x3d657a6953477b43 ...
argumentType(3)[0] == 'd'
```

### 2.2 两个替换实现

```c
// 0x462c
static id ResourceImage(id self, SEL _cmd, CGSize size, double scale) {
    if (mode 无效 || mode == 2) goto passthrough;
    if (!isnormal(size.width) || !isnormal(size.height) || !isnormal(scale)) goto passthrough;

    id catalog = [self catalog];
    NSString *name = [self imageName];
    uint32_t appearance = [self respondsToSelector:@selector(catalogAppearance)]
                        ? (uint32_t)[self catalogAppearance] : 0;
    if (appearance > 2) goto passthrough;
    if (!catalog || !name.length) goto passthrough;
    if (!NGCatalogHasStack(catalog, name)) goto passthrough;   // 不是分层图标 → 交给系统

    uint32_t px = clamp((uint32_t)ceil(fmax(size.width, size.height) * scale), 16, 1024);

    CGImageRef img = (mode == 1)
        ? NGCreateGlassIconContent(catalog, name, appearance, px)   // 玻璃
        : NGCreateFlatIcon(catalog, name, appearance, px);          // 扁平重建
    return WrapImage(img, (double)px / scale);
passthrough:
    return OriginalResourceImage(self, _cmd, size, scale);
}
```

```c
// 0x48e0
static id ComposedImage(id self, SEL _cmd, CGSize size, double scale) {
    id original = OriginalComposedImage(self, _cmd, size, scale);
    if (!(mode & 1)) return original;                        // 只有 1 / 3 处理
    if (![original respondsToSelector:@selector(CGImage)] || ![original respondsToSelector:@selector(scale)])
        return original;

    id elements = ReadProperty(self, @"elements");            // KVC，带 @try
    id first    = [elements respondsToSelector:@selector(firstObject)] ? [elements firstObject] : nil;
    id recipe   = ReadProperty(first, @"recipe") ?: ReadProperty(self, @"recipe");
    if (![recipe isKindOfClass:ISiOSAppRecipe]) return original;

    CGImageRef cg = [original CGImage];
    if (!cg || CGImageGetWidth(cg) != CGImageGetHeight(cg) || CGImageGetWidth(cg) > 1024) return original;

    CGImageRef out = (mode == 1 && HasLayeredPrimaryResource(self))
        ? NGCreateRimmedImage(cg)
        : NGCreateGlassedImage(cg, 0);
    return WrapImage(out, [original scale]) ?: original;
}
```

`ReadProperty`（0x4c88）= `@try { [obj valueForKey:key] } @catch { nil }`。
`WrapImage`（0x4bec）= `[[IFImage alloc] initWithCGImage:img scale:s]` 然后 `CGImageRelease(img)`。

### 2.3 分层图标数据结构（本次还原出的核心格式）

Apple 的 `.icon` 资源经 CUICatalog 暴露成一组 `NGRendition`。插件定义了 4 个类来读它：

```
NGRendition      : _layout(u32) _pixelFormat(u32) _width(u32) _height(u32)
                   _key(NSData*) _csi(NSData*) _name(NSString*)
NGLayerRef       : _lighting(BOOL) _specular(BOOL) _blendMode(u32) _flags(u32)
                   _opacity(f32) _blur(f32) _translucency(f32)
                   _shadowStyle(u32) _shadowOpacity(f32)
                   _keyList(NSData*) _fill(NSString*) _frame(CGRect)
NGCatalogIndex   : _renditions(NSArray*) _tokens(NSArray*) _appearances(NSDictionary*)
NGGradient       : _type(i64) _colors(NSArray*) _stops(NSArray*) _start(CGPoint) _end(CGPoint)
```

**`NGRendition._key` 布局** —— 属性包，`uint16` 对数组：

```
+0x00  u16 key0     +0x02  u16 value0
+0x04  u16 key1     +0x06  u16 value1
...
```
`keyValue(rendition, k)` 线性查表返回 value（找不到返回 0）。**key 7 = theme/appearance id**。

**`NGRendition._csi` 布局** —— ISTC 容器（**已逐字段确认**）：

```
+0x000 u32 magic = 'ISTC' (0x43545349)
+0x00C u32 width          +0x010 u32 height        +0x018 u32 pixelFormat
+0x024 u16 layout         +0x028 char name[0x80]   (NUL 结尾)
+0x0A8 u32 recordsSize    —— 0x0B8 起记录区的长度（同时也是载荷偏移）
+0x0B4 u32 payloadSize    —— 主数据块长度
+0x0B8 记录区: { u32 tag; u32 len; u8 body[len]; } * N
+0x0B8+recordsSize  主数据块（渐变 / 颜色 / 图像 / SVG）
```

记录 `tag` 与 `layout` 共用同一套值。旧版本文档里把它写成"图层表"是不完整的：

| tag | 内容 | 填充到 |
|---|---|---|
| `0x3F4` | `u32 count` + count × `{u32 flags; i32 x; i32 y; u32 w; u32 h; u32 blendMode; float opacity; u32 keyLen; u8 key[keyLen];}` | 新建 `NGLayerRef`，填 frame/blendMode/opacity/keyList |
| `0x3FC` | `u32 count` + count × `{u32 flags(bit0=lighting); float blur; u32 fillLen; char fill[fillLen];}` | 回填 lighting / blur / fill |
| `0x3FD` | `u32 count` + count × `{u32 flags(bit0=specular); float translucency; u32 shadowStyle; float shadowOpacity; u32 pad;}`（步长 0x14） | 回填 specular / translucency / shadow |
| `0x3FB` | iconstack 本体 | `findStack` 只认这个 layout |
| `0x3F9` / `9` | 图像（SVG 或 CUIImage） | `drawContents` 走 CoreSVG / `_themeStore` |

`layerRefs()` 三趟填的是**同一批** `NGLayerRef` 对象（第一趟建对象，后两趟按下标回填）。

**`NGLayerRef._keyList`** 与 `_key` 同构（`uint16` 对数组）。`resolve(catalog, keyList, theme)`：
遍历 `index.renditions`，对每个候选 r 逐对比较 `keyValue(r, k) == v`，全部命中后再比
`keyValue(r, 7) == theme`。没命中时还有一层「候选回退」（`resolve` 里的 x23/x22 两个槽）。

**`layout` 码**（`drawNode` 的分派开关）：

| 值 | 十进制 | 含义 | 处理 |
|---|---|---|---|
| `0x3F1` | 1009 | 纯色/渐变填充层 | `drawFill(...)`；`ctx->foregroundOnly` 时跳过 |
| `0x3FC` | 1020 | 组（group） | 递归 `drawNode`，外面套 `BeginTransparencyLayer` |
| `0x3FD` | 1021 | 同 1009（另一种填充） | 同 1009 |
| 其他 | | 位图 / SVG 元素 | `drawElement(...)` |

### 2.4 绘制上下文

```c
typedef struct {                 // 0x68 字节，栈上
    size_t px;                   // +0x00  目标像素边长（已 clamp 到 16..1024）
    size_t px2;                  // +0x08  同上（重复一份）
    CGAffineTransform ctm;       // +0x10  = translate(0, px) * scale(px/w, -px/h)
    CGPoint origin;              // +0x40  默认 frame.origin
    CGSize  size;                // +0x50  默认 frame.size = (w, h)
    BOOL    foregroundOnly;      // +0x60  == (appearance == 2)，tintable 时只画前景
} DrawCtx;
```

位图：`CGBitmapContextCreate(NULL, px, px, 8, 0, kCGColorSpace*, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little)`
→ **BGRA8 预乘**，`CGContextSetInterpolationQuality(ctx, 3)`（high）。

### 2.5 三种图像生成器

| 函数 | 地址 | 用途 |
|---|---|---|
| `NGCreateFlatIcon` | 0x60e4 | 只用 `layers` 重画（Mode 0 / Mode 3） |
| `NGCreateGlassIcon` | 0x68f8 | 玻璃质感全流程（Mode 1） |
| `NGCreateRimmedImage` | 0x9324 | 只描边（Composed + Mode 1） |
| `NGCreateGlassedImage` | 0x996c | 通用玻璃化（Composed + Mode 3） |

`NGCreateFlatIcon` 完整流程（已逐指令还原）：

```c
CGImageRef NGCreateFlatIcon(catalog, name, appearance, px) {
    if (!catalog || !name || !px) return NULL;

    NGCatalogIndex *index = indexFor(catalog);
    id stack = findStack(index, name, appearance);
    uint32_t app = appearance;
    if (appearance == 2 && !stack) { stack = findStack(index, name, 0); app = 0; }  // tintable 回退
    if (!stack) return NULL;

    BOOL tintable = (appearance == 2);
    NSString *appName = app == 2 ? @"ISAppearanceTintable"
                      : app == 1 ? @"UIAppearanceDark" : @"UIAppearanceLight";
    uint16_t theme = [index.appearances[appName] unsignedShortValue];

    double w = stack.width  ?: 1024;      // 0x400
    double h = stack.height ?: 1024;

    DrawCtx ctx = {0};
    ctx.px = px; ctx.px2 = px;
    ctx.ctm = CGAffineTransformIdentity;
    ctx.size = CGSizeMake(w, h);
    ctx.foregroundOnly = tintable;
    CGAffineTransform t = CGAffineTransformMakeTranslation(0, px);
    ctx.ctm = CGAffineTransformScale(t, px / w, -px / h);

    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, 0x2002);
    CGContextSetInterpolationQuality(c, 3);
    CGContextConcatCTM(c, ctx.ctm);

    if (appearance == 2) {                       // tintable：先铺白
        CGContextSetGrayFillColor(c, 0, 1);
        CGContextFillRect(c, CGRectMake(0, 0, w, h));
    }
    BOOL ok = drawNode(c, &ctx, catalog, index, stack, theme);

    if (appearance == 2 && ok) {                 // tintable：转 Rec.709 灰度
        uint8_t *base = CGBitmapContextGetData(c);
        size_t stride = CGBitmapContextGetBytesPerRow(c);
        size_t W = CGBitmapContextGetWidth(c), H = CGBitmapContextGetHeight(c);
        for (y) for (x) {
            uint8_t *p = base + y*stride + x*4;       // BGRA
            double luma = p[0]*0.0722 + p[1]*0.7152 + p[2]*0.2126 + 0.5;
            if (luma > 255) luma = 255;
            int v = (int)luma;
            if (p[3] < v) v = p[3];
            p[0] = p[1] = p[2] = (uint8_t)v;          // alpha 保持不变
        }
    }
    CGImageRef out = ok ? CGBitmapContextCreateImage(c) : NULL;
    CGContextRelease(c);
    return out;
}
```

Rec.709 亮度系数（`__TEXT/__const+0x8/0x10/0x18` = **0.7152 / 0.0722 / 0.2126**）已实读确认。

### 2.6 drawNode / drawElement

```c
BOOL drawNode(CGContextRef c, DrawCtx *ctx, id catalog, NGCatalogIndex *index,
              NGRendition *node, uint16_t theme)
{
    BOOL ok = YES;
    for (NGLayerRef *ref in layerRefs(node.csi)) {
        id target = resolve(catalog, ref.keyList, theme);
        if (!target) { NGLog(@"%@: unresolved ref %@", node.name, keyListDesc(ref.keyList)); ok = NO; continue; }

        CGRect frame = (ref.frame.size.width > 0 && ref.frame.size.height > 0)
                     ? ref.frame : CGRectMake(ctx->origin.x, ctx->origin.y, ctx->size.width, ctx->size.height);

        if (target.layout == 0x3FD || target.layout == 0x3F1) {
            if (ctx->foregroundOnly) continue;
            CGContextSaveGState(c);
            CGContextSetAlpha(c, ref.opacity);
            ok &= drawFill(c, catalog, target.name, theme, 1, frame);
            CGContextRestoreGState(c);
        } else if (target.layout == 0x3FC) {
            CGContextSaveGState(c);
            CGContextSetAlpha(c, ref.opacity);
            CGContextSetBlendMode(c, ref.blendMode);
            CGContextBeginTransparencyLayer(c, NULL);
            ok &= drawNode(c, ctx, catalog, index, target, theme);
            CGContextEndTransparencyLayer(c);
            CGContextRestoreGState(c);
        } else {
            ok &= drawElement(c, ctx, catalog, index, target, ref, theme, frame);
        }
    }
    return ok;
}
```

---

## 3. FlatGlassRefresh.dylib —— SpringBoard 侧

完整源码见 `FlatGlass/FlatGlassRefresh/FlatGlassRefresh.m`（已 100% 还原）。

要点：
- 两个 `notify_register_check` 暴露自己的进度（`reloaded-icons` / `refreshed-views`），供外部调试。
- 收到模式变更后**先等 2 秒**（等 iconservicesagent 自杀重生），再用 `RefreshGeneration` 代号作废旧任务。
- 私有 API 全部经过「存在 + 参数个数 + 返回类型」三重校验：`enumerateLeafIconsUsingBlock:`、`purgeAllCachedImages`、`purgeAllCachedFolderImages`、`reloadIconImage`、`clearCachedImages`、`updateImageAnimated:`。
- 分批 4 个 / 0.4 秒，避免主线程长时间占用。

---

## 4. flatglass CLI —— 守护进程

（详细还原见 `FlatGlass/flatglass/`，此处为架构摘要）

四个入口：

| 参数 | 行为 |
|---|---|
| `--watch` | 常驻。`notify_register_check` + `notify_register_dispatch("...settings-changed")`，随后 `dispatch_main()` |
| `--disable` | 注销 SnowBoard 主题、`notify_set_state(0)`、发通知、清理 |
| `--preview-scan` | 扫描 `/Applications`、`/var/containers/Bundle/Application`、`/var/jb/Applications`，用 `FlatRenderer` 重渲染 PNG 到 SnowBoard 主题目录 |
| `--gloss-icon` | 单独给某个图标生成 gloss 变体（含 `hypotf` 的像素径向运算） |

`--watch` 的循环体：
1. 读 plist `Mode`；
2. `notify_set_state(token, mode + 1)` + `notify_post("...iconservices-mode")`；
3. 同步 SnowBoard：三个主题目录 `FlatGlass.theme` / `FlatGlass Gloss.theme` / `FlatGlass Edge.theme`，
   按模式把其中一个（或都不）写进 `com.spark.snowboardprefs.plist` 的 `ActiveMenuItems`，
   发 `com.spark.snowboard.refreshNow`。

缓存文件 `/var/jb/Library/Themes/.../Apps.plist`：每条
`{ key: "3|<bundleid>|<iconName>|<version>|<...>|...", rendered: BOOL, nativeHighlight: int }`。

---

## 5. 常量与魔法数索引

| 常量 | 值 | 位置/用途 |
|---|---|---|
| Rec.709 亮度 | 0.7152 / 0.0722 / 0.2126 | `__const+0x8/0x10/0x18`，tintable 灰度化 |
| 默认图标边长 | 1024 | `NGCreateFlatIcon` 的 width/height 兜底 |
| 像素下限/上限 | 16 / 1024 | `ResourceImage` clamp |
| 模式等待 | 2.0 s | SpringBoard 侧 `dispatch_after` |
| 批大小/间隔 | 4 个 / 0.4 s | `RefreshBatch` |
| `IG_STEPS` | 环境变量 | 高斯模糊步数（IconGlare 遗留） |
| squircle 相关 | 671.7955933 / 773.2112427 / 823.9190674 / 878.5038452 / 938.1013794 / 985.0487061 / 1006.740417 / 17.25958443 / 38.95132065 / 85.89861298 / 145.49617 / 200.0809631 / 250.7887726 / 352.2044067 | `__TEXT/__const+0x1e0..0x248`，见 §6 |
| π/2 | 1.5707963267948966 | `__const+0x1d8` |
| 收敛阈值 | 0.01 | `__const+0x48` |

---

## 6. 玻璃高光管线（IconGlare 移植部分）

> 这批函数是从 https://github.com/evgeniy558/IconGlare 移植的 C 代码，
> 逻辑是：**由 alpha 生成形状遮罩 → 距离变换求内侧带宽 → 高斯模糊得到柔和过渡 → 沿法线做高光/描边**。

函数清单（地址 / 作用）：

| 地址 | 符号 | 作用 |
|---|---|---|
| 0xbde4 | `blurPlane` | 单平面模糊的薄封装 |
| 0xbde8 | `IGGaussianBlurPublic` | 对外的高斯模糊入口 |
| 0xbdec | `IGDrawGroup` | 主绘制组：图层合成 |
| 0xcf50 | `gaussianBlur` | 可分离高斯（水平 + 垂直两趟） |
| 0xd0d0 | `IGDrawChicletHighlights` | **图标本体高光**（"artwork" 那部分） |
| 0xd568 | `edt` | 欧氏距离变换（Felzenszwalb 两趟） |
| 0xd9f4 | `IGDrawOutline` | **描边**（"edge" 那部分） |
| 0xddbc | `IGCreateIconShape` | 生成 squircle 形状遮罩 |
| 0xe320 | `boxPass` | 盒式模糊单趟 |

> 逐行伪代码见 `FlatGlass/FlatGlassIconServices/FGIconGlare.c`（由反汇编还原，带地址标注）。

---

## 7. 还原工程结构与编译

```
FlatGlass/
├── Makefile                     # 聚合 4 个子工程，THEOS_PACKAGE_SCHEME=rootless
├── control
├── layout/                      # 资源与安装脚本（原样取自 deb）
│   ├── DEBIAN/{postinst,prerm}
│   └── Library/{MobileSubstrate,LaunchDaemons,PreferenceLoader,PreferenceBundles}/...
├── FlatGlassIconServices/       # 渲染器 dylib
├── FlatGlassRefresh/            # SpringBoard dylib
├── FlatGlassPrefs/              # 设置面板 bundle
└── flatglass/                   # CLI 守护进程
```

编译：`make package FINALPACKAGE=1`（需要 Theos + iOS 15+ SDK）。

---

## 8. 待修复 / 待验证清单

| # | 项 | 证据 | 建议 |
|---|---|---|---|
| 1 | Mode 1/3 标签与行为互换 | §1.2（两条路径一致地反着来） | 要么交换 `validValues`，要么交换 `ResourceImage` 里 `mode == 1` 的判断 |
| 2 | iOS 26 下 Mode 3 退化为 Mode 0 | `ResourceImage` 只有 `mode == 1` 走玻璃 | 若要"Edge Only"在分层图标上生效，需在 `NGCreateFlatIcon` 路线里补 `NGCreateRimmedImage` 式描边 |
| 3 | `writeMode:` 会覆盖整份 plist | §4（字典只含 `Mode`） | 加新键前必须改成 读-改-写 |
| 4 | `NGLog` 恒为 NULL | `__common` 里无写入点 | 若要开日志，需在 `%ctor` 里赋值 |
| 5 | `describe` / `NGDescribeStack` 是死代码 | 无调用者 | 保留作调试工具 |
| 6 | 绘制常量语义（§5 squircle 那批） | 只能从上下文推断 | 需在设备上逐模式截图对比 |

---

## 9. 地址索引（便于以后对二进制复查）

### FlatGlassIconServices.dylib（基址 0）

```
0x4000 StartFlatGlassIconServices      0x4224 IsImageRenderer
0x4308 notify block                    0x4310 InvalidateCache
0x462c ResourceImage                   0x48e0 ComposedImage
0x4bec WrapImage                       0x4c88 ReadProperty
0x4cfc HasLayeredPrimaryResource       0x5088 NGCatalogHasStack
0x5114 findStack                       0x53ac indexFor
0x5764 NGDescribeStack                 0x5948 describe
0x60e4 NGCreateFlatIcon                0x64cc drawNode
0x68cc NGCreateGlassIconContent        0x68f8 NGCreateGlassIcon
0x7e68 layerRefs                       0x7f98 resolve
0x81e4 drawFill                        0x8c60 drawElement
0x9324 NGCreateRimmedImage             0x996c NGCreateGlassedImage
0xacc4 keyValue                        0xaf78 rawData
0xb194 keyListDesc                     0xb5ac byName
0xb7a8 createColor                     0xb9e8 drawContents
0xbdec IGDrawGroup                     0xcf50 gaussianBlur
0xd0d0 IGDrawChicletHighlights         0xd568 edt
0xd9f4 IGDrawOutline                   0xddbc IGCreateIconShape
0xe320 boxPass
```

### 全局变量

```
0x18d28 ModeToken (int)                0x18d30 ImageClass
0x18d38 AppRecipeClass                 0x18d40 ResourceClass
0x18d48 OriginalResourceImage          0x18d50 OriginalComposedImage
0x18d58 HasLayeredPrimaryResource.primaryKey
0x18d60 ...once                        0x18d68 gGlassNoEdge (BOOL)
0x18da8 NGLog (函数指针，默认 NULL)
```


---

## 10. 本轮新增的精确参数（第二轮深挖）

### 10.1 `gGlassNoEdge` 的真实语义

```c
NGCreateGlassIconContent(...) {      // 只有 Mode 1 走这里
    gGlassNoEdge = 1;
    img = NGCreateGlassIcon(...);
    gGlassNoEdge = 0;
    return img;
}
```
`gGlassNoEdge` 只在 `IGDrawChicletHighlights` 调用前判断（0x7C60）；
`IGDrawOutline` **无条件执行**。所以：

- `gGlassNoEdge = 1` → 只画描边、不画 chiclet 高光 → **"Edge Only" 的观感**
- `gGlassNoEdge = 0` → 高光 + 描边 → **"Edge and Artwork" 的观感**

而它被设在 **Mode 1**（plist 标为 "Edge and Artwork"）。这就从指令层面坐实了 §1.2 的结论：
**1.8.4 的两个模式标签与实现是反的。**

### 10.2 图标形状：四段三次贝塞尔（不是超椭圆公式）

`IGCreateIconShape`（0xDDBC）在设计空间 1024×1024 里用 4 段旋转对称的贝塞尔画 squircle，
每段 3 条三次曲线，常量（实读，12 个 double）：

```
P0 = 671.795593262
c1 = {773.211242676, 0}, {823.919067383, 0}, {878.503845215, 17.2595844269}
c2 = {938.101379395, 38.9513206482}, {985.048706055, 85.8986129761}, {1006.740417480, 145.496170044}
c3 = {1024, 200.080963135}, {1024, 250.788772583}, {1024, 352.204406738}
```
四组关于 45° 线对称（1024−671.7956 = 352.2044 …），变换为
`Translate(cen,cen) · Rotate(i·π/2) · Translate(−cen,−cen) · Scale(n/1024)`。

### 10.3 描边（`IGDrawOutline`）实测参数

```
style ∈ (0.2, 0.99)  -> 直接 return（不描边）
style ≤ 0.2          -> 白色描边，增益 0.15
style ≥ 0.99         -> 黑色描边，增益 0.12
半宽  w = (n/1024) * 2.6667 * 0.5  =  n / 768
覆盖  cov = clamp01(w - |sdf + 0.5 - alpha| + 0.5)
sdf 内部 = −(sqrt(d_toOutside) − 0.5)，外部 = +(sqrt(d_toInside) − 0.5)
```

### 10.4 Chiclet 高光（`IGDrawChicletHighlights`）

两个相隔 180° 的斜向方位窗 `kP1`（7/32 圈 = 78.75°）/ `kP2`（6/32 圈 = 67.5°），
查表 32 级线性插值；相位 `(θ+3π/4)/2π` 与 `(θ−π/4)/2π`。带宽 `22·n/1024`。合成：

```
c' = min(1, min(1, c + 0.0796·cov) · (1−a) + 1.1·a)      // 0.0796 = 1/4π
```

### 10.5 模糊

`gaussianBlur` 是 **固定 3 趟盒式**（Kutskir 公式推 3 个半径），与 `IG_STEPS` 无关；
`boxPass` 越界样本按 **0** 计（不是 clamp），所以贴边会变暗。
`IG_STEPS` 只是 `IGDrawGroup` / `Chiclet` 里的**位掩码开关**（缺省 1503 = 0b101_1101_1111）。

### 10.6 `NGCreateRimmedImage` 的巧思

它 **不写 alpha 通道**：alpha 沿用先前 `CGContextDrawImage` 画进去的源图 alpha，
只把 RGB 换成 `highlight × alpha` 再重新预乘。这就是"只加一道边、不动图案"的实现方式。

### 10.7 常量池澄清

`__TEXT/__const+0x00`（0x10B50）**不是浮点表**，而是 block literal 的
`{flags = 0xC2000000, reserved = 0}` 8 字节字（编译器用来在栈上构造 block）。
Rec.709 的三个系数确实在 `0x10B58 / 0x10B60 / 0x10B68` = 0.7152 / 0.0722 / 0.2126，
但只被 `NGCreateFlatIcon`（0x63A4）和 `drawFill`（0x880C）使用。
