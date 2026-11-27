//
//  FGInternal.h
//  FlatGlassIconServices — 内部类型与函数声明
//
//  类名、ivar 名、函数名、地址都保持与原二进制一致，方便以后逐条对回反汇编。
//

#ifndef FG_INTERNAL_H
#define FG_INTERNAL_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <notify.h>
#include "FGRenderPolicy.h"

#pragma mark - 绘制上下文

// 原二进制里是栈上 0x68 字节的匿名结构体，所有绘制函数都传它。
typedef struct FGDrawContext {
    size_t            pixelWidth;    // +0x00
    size_t            pixelHeight;   // +0x08
    CGAffineTransform ctm;           // +0x10  translate(0,px) * scale(px/w, -px/h)
    CGPoint           origin;        // +0x40  元素的默认原点
    CGSize            size;          // +0x50  元素的默认尺寸
    BOOL              foregroundOnly;// +0x60  tintable 外观时只画前景
} FGDrawContext;

#pragma mark - 分层图标数据模型（原样对应 4 个私有类）

// NGRendition —— 一条渲染条目。属性来自 ISTC 容器头。
@interface NGRendition : NSObject
@property (nonatomic, assign) uint32_t layout;       // +0x24 u16（这里用 u32 存）
@property (nonatomic, assign) uint32_t pixelFormat;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, strong) NSData   *key;         // u16 键值对序列
@property (nonatomic, strong) NSData   *csi;         // ISTC 容器
@property (nonatomic, copy)   NSString *name;
@end

// NGLayerRef —— 一层的绘制参数。
@interface NGLayerRef : NSObject
@property (nonatomic, assign) BOOL     lighting;
@property (nonatomic, assign) BOOL     specular;
@property (nonatomic, assign) uint32_t blendMode;
@property (nonatomic, assign) uint32_t flags;
@property (nonatomic, assign) float    opacity;
@property (nonatomic, assign) float    blur;
@property (nonatomic, assign) float    translucency;
@property (nonatomic, assign) uint32_t shadowStyle;
@property (nonatomic, assign) float    shadowOpacity;
@property (nonatomic, strong) NSData   *keyList;
@property (nonatomic, strong) NSString *fill;
@property (nonatomic, assign) CGRect   frame;
@end

// NGCatalogIndex —— 一次性索引好的 catalog 快照。
@interface NGCatalogIndex : NSObject
@property (nonatomic, strong) NSArray      *renditions;
@property (nonatomic, strong) NSArray      *tokens;
@property (nonatomic, strong) NSDictionary *appearances;
@end

// NGGradient —— drawFill 里解析出来的渐变描述。
@interface NGGradient : NSObject
@property (nonatomic, assign) int64_t  type;
@property (nonatomic, strong) NSArray *colors;
@property (nonatomic, strong) NSArray *stops;
@property (nonatomic, assign) CGPoint  start;
@property (nonatomic, assign) CGPoint  end;
@end

#pragma mark - 全局状态（地址见报告 §9）

extern int  FGModeToken;                 // 0x18d28  对应原 ModeToken
extern Class FGImageClass;               // 0x18d30  IFImage
extern Class FGAppRecipeClass;           // 0x18d38  ISiOSAppRecipe
extern Class FGResourceClass;            // 0x18d40  ISAssetCatalogResource
extern IMP  FGOriginalResourceImage;     // 0x18d48
extern IMP  FGOriginalComposedImage;     // 0x18d50

// 日志钩子，默认 NULL（原二进制从不给它赋值）。调试时在 %ctor 里设成 NSLog 即可。
extern void (*FGLog)(NSString *message);

#pragma mark - 常量

#define FG_DEFAULT_SIDE      1024.0
#define FG_LAYOUT_GROUP      1020      // 0x3fc
#define FG_LAYOUT_FILL       1021      // 0x3fd
#define FG_LAYOUT_FILL_ALT   1009      // 0x3f1
#define FG_LAYOUT_IMAGE      1017      // 0x3f9
#define FG_LAYOUT_IMAGE_ALT  9

#pragma mark - 函数

// 模式
int  FGCurrentMode(void);                  // 返回 0..3，无效返回 -1

// catalog 解析（FGCatalog.m）
NGCatalogIndex *FGIndexFor(id catalog);
id              FGFindStack(NGCatalogIndex *index, NSString *name, uint32_t appearance);
NGRendition    *FGByName(NGCatalogIndex *index, NSString *name, uint16_t theme);
NSArray        *FGLayerRefs(NSData *csi);
NGRendition    *FGResolve(id catalog, NSData *keyList, uint16_t theme);
uint16_t        FGKeyValue(NGRendition *r, uint16_t key);
NSString       *FGKeyListDesc(NSData *keyList);
NSData         *FGRawData(NGRendition *r);
CGColorRef      FGCreateColor(NGRendition *r);
BOOL            FGHasLayeredPrimaryResource(id firstElement);
BOOL            FGHasStack(id catalog, NSString *name);   // = findStack(indexFor(c), name, 0) != nil

// 绘制（FGDraw.m）
BOOL FGDrawNode(CGContextRef c, FGDrawContext *ctx, id catalog,
                NGCatalogIndex *index, NGRendition *node, uint16_t theme);
BOOL FGDrawElement(CGContextRef c, FGDrawContext *ctx, id catalog,
                   NGCatalogIndex *index, NGRendition *target,
                   NGLayerRef *ref, uint16_t theme, CGRect frame);
BOOL FGDrawFill(CGContextRef c, NGCatalogIndex *index, NSString *fillName,
                uint16_t theme, int forceVertical, CGRect frame);
BOOL FGDrawContents(CGContextRef c, id catalog, NGRendition *r, CGRect frame);

// 生成（FGCreate.m / FGGlass.m）
CGColorSpaceRef FGSharedExtendedSRGB(void);

// IconGlare 原语（FGIconGlare.m）
float *FGIconShape(int n);                       // n*n 的 squircle 覆盖率（1.0 = 实心）
void   FGGaussianBlur(float *plane, int n, float sigma);
void   FGBoxPass(float *plane, float *row, int n, int r, int dir);
#include "FGContourPaint.h"

CGImageRef NGCreateFlatIcon(id catalog, NSString *name, uint32_t appearance, size_t px);
CGImageRef NGCreateGlassIcon(id catalog, NSString *name, uint32_t appearance, size_t px);
CGImageRef NGCreateGlassIconContent(id catalog, NSString *name, uint32_t appearance, size_t px);
CGImageRef NGCreateRimmedImage(CGImageRef src);
CGImageRef NGCreateGlassedImage(CGImageRef src);
id         FGWrapImage(CGImageRef img, double scale);

#endif /* FG_INTERNAL_H */
