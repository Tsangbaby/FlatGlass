# FlatGlass 1.8.4 · RootHide 测试版 2

FlatGlass 是主屏图标高光插件。此工程由 `local.lumid.flatglass_1.8.4_iphoneos-arm64.deb` 还原，保留原包身份和署名；`1.8.4+roothide.test2` 是此工作树的测试版本，不是原作者的发布包。

## test2 修复

- `Edge Only` 的旧式合成分支现在沿图标轮廓叠加方向性内缘高光；描边和 `Edge and Artwork` 的高光共享一次到外部像素的精确距离计算，不再按到图标中心的距离上色。两个旧式合成入口保留源图 alpha。轮廓曲线的控制点按原包分组。
- `Edge and Artwork` 判断有无分层主资源时查询 `elements.firstObject`，不误查合成器。未命中现有私有接口／输入不兼容时保持系统回退。
- 缓存标记从 `1:<mode>` 升到 `2:<mode>`，避免在新版渲染器已加载时把 test1 的旧图误判为最新；不改偏好、不增加设备自动重启逻辑。
- 完整的多层玻璃材质、离线 PNG 及 iOS 26 分层图标的模式行为不在此轮改动中。`Remove Highlights` 对普通非分层图标并非生效指标。

## 构建

使用完整 Xcode（CI 固定 16.4）、[官方 roothide/theos](https://github.com/roothide/theos/tree/958fea4f779943505b15b93c88bb4db8d97b346d) 和递归子模块、`ldid`、`rsync`、GNU make 与 Debian 打包工具。需在 `$THEOS/sdks` 放入带 `Preferences.framework/Preferences.tbd` 的 iPhoneOS SDK（CI 固定 [theos/sdks iPhoneOS16.5](https://github.com/theos/sdks/tree/0222fd5413cf4b9af096f37b4621afa2688572f7/iPhoneOS16.5.sdk)）；Preferences 私有头由所固定 Theos 的 `vendor/include` 提供。

```sh
export THEOS=/path/to/roothide-theos
gmake package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide \
  TARGET=iphone:clang:16.5:15.0 THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip
python3 Scripts/validate_package.py packages/local.lumid.flatglass_1.8.4+roothide.test2_iphoneos-arm64e.deb
```

`arm64` / `arm64e` 是 Mach-O 切片；`iphoneos-arm64e` 是 RootHide 的包架构。`15.0` 是最低编译部署目标，不是实际测试过的系统范围。也可显式选择 `THEOS_PACKAGE_SCHEME=rootless` 做传统 rootless 构建；请清理对象目录或用独立工作树，勿混用两方案的暂存目录或把两种包当作可互换。自动验证器针对本轮的 RootHide 候选。

## 内容和边界

- `FlatGlassIconServices/`：以 `iconservicesagent` 为目标，重建分层图标及合成边缘效果。关键私有消息用已核对的 ABI；签名对不上时返回系统渲染。玻璃多通道合成仍为近似，视觉未与原包逐像素对齐。
- `FlatGlassRefresh/`：SpringBoard 侧，当模式变化时清理相关缓存并分批更新图标。仍依赖目标 iOS 的私有接口和系统进程加载能力。
- `FlatGlassPrefs/`、`flatglass/`、`Shared/`：设置、模式广播和共享偏好。RootHide 两端用同一 jbroot 路径，**不迁移或覆盖旧 rootless 偏好**，无新偏好时为模式 0。四档原值 `0, 3, 1, 2` 不变；数值 `0…3` 映射到通知 state `1…4`。守护首发失败退出；`--disable` 只发送 state `3`，不覆盖保存模式。SnowBoard 清理只摘掉 FlatGlass 自己的主题，不添加主题。
- CLI 仅支持 `--watch` 和 `--disable`。原包的 `--preview-scan`、`--gloss-icon` 和 `Assets.car` 位置参数渲染均未实现；拒绝调用并返回非零，不生成 PNG、不误发模式。
- `layout/`：两个注入 filter、launchd job、维护脚本和设置资源。RootHide 依赖目标 bootstrap 自带的 `launchctl` 解析 jbroot 路径。标准系统框架与系统图标缓存仍用系统路径。
- `reverse-reference/` 和 [原还原记录](FlatGlass_REVERSE_ENGINEERING.md) 是历史分析线索，不参与编译，也不保证每条伪代码都正确。

## 验证

`Tests/run-contour-tests.sh` 用真实生产 C 算子比较 120/180 px 的硬边、抗锯齿、透明及独立形状/覆盖输入。可选 `--against-test1` 对旧提交做同一对照，预期以像素断言失败结束。`Tests/run-contour-cg.sh` 在 macOS 的 CoreGraphics 上调用实际的 Rimmed/Glassed 函数，核对边缘变化、中心与透明度；`Tests/run-layer-probe.sh` 用受控本地对象验证生产分层判断。另保留 test1 的模式、尺寸和维护脚本模拟测试。CI 要求六组测试全部通过，再签名和验包。

**构建和宿主图像测试通过不代表真机桌面一定走此路径。** iOS 15/16 建议比较同一中深色普通图标在 Off 和 Edge Only 之间的外缘差异。iOS 26 的分层资源 Mode 3 仍走原来的扁平分支。未在目标机上验证注入、缓存更新或所有 App 的图标。
