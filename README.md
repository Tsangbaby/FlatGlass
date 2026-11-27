# FlatGlass 1.8.4 · RootHide 测试版 1

FlatGlass 是主屏图标高光插件。此工程由 `local.lumid.flatglass_1.8.4_iphoneos-arm64.deb` 还原，保留原包身份和署名；`1.8.4+roothide.test1` 是此工作树的测试版本，不是原作者的发布包。

## 构建

使用完整 Xcode（CI 固定 16.4）、[官方 roothide/theos](https://github.com/roothide/theos/tree/958fea4f779943505b15b93c88bb4db8d97b346d) 和递归子模块、`ldid`、`rsync`、GNU make 与 Debian 打包工具。需在 `$THEOS/sdks` 放入带 `Preferences.framework/Preferences.tbd` 的 iPhoneOS SDK（CI 固定 [theos/sdks iPhoneOS16.5](https://github.com/theos/sdks/tree/0222fd5413cf4b9af096f37b4621afa2688572f7/iPhoneOS16.5.sdk)）；Preferences 私有头由所固定 Theos 的 `vendor/include` 提供。

```sh
export THEOS=/path/to/roothide-theos
gmake package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide \
  TARGET=iphone:clang:16.5:15.0 THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip
python3 Scripts/validate_package.py packages/local.lumid.flatglass_1.8.4+roothide.test1_iphoneos-arm64e.deb
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

`Tests/` 的脚本覆盖可移植的模式/尺寸逻辑和模拟的维护脚本调用，不访问真实 notifyd、SpringBoard 或 launchd。GitHub Actions 在云 Mac 构建、签名并检查包结构；**构建成功不代表真机可用**。真机还须确认设置能打开与保存、守护常驻、两个系统进程加载、支持的图标实际改变、Off 和卸载都能恢复。iOS 26 分层图标的 Mode 3 鉴于原版行为仍走扁平分支，不宣称 Edge Only 在该路径画出了边缘。
