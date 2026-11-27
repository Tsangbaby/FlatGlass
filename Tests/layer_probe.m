// Host executable: compile the real catalog probe and static ComposedImage in
// this TU. Only system state, input objects and drawing are supplied locally.
#import <stdio.h>
#import <stdlib.h>
#import "../FlatGlassIconServices/FGCatalog.m"

static uint64_t state;
static unsigned probes;
static id receiver;
static uint32_t LocalState(int token, uint64_t *out) {
    if (token != 1) abort();
    *out = state;
    return NOTIFY_STATUS_OK;
}
static BOOL CountProbe(id object) {
    ++probes; receiver = object;
    return FGHasLayeredPrimaryResource(object);
}
// Headers are already imported. Do not register a constructor, replace any
// methods or call notifyd, even if this test is accidentally renamed.
#define constructor unused
#define notify_get_state LocalState
#define FGHasLayeredPrimaryResource CountProbe
#import "../FlatGlassIconServices/FlatGlassIconServices.m"
#undef FGHasLayeredPrimaryResource
#undef notify_get_state
#undef constructor

@interface ProbeImage : NSObject <FGPrivateImage> {
    CGImageRef _cg;
    CGFloat _scale;
}
@end
@implementation ProbeImage
- (instancetype)initWithCGImage:(CGImageRef)cg scale:(CGFloat)scale {
    if ((self = [super init])) { _cg = CGImageRetain(cg); _scale = scale; }
    return self;
}
- (CGImageRef)CGImage { return _cg; }
- (CGFloat)scale { return _scale; }
- (void)dealloc { CGImageRelease(_cg); }
@end

@interface ProbeRecipe : NSObject @end
@implementation ProbeRecipe @end
@interface ProbeAsset : NSObject
@property(nonatomic, strong) id catalog;
@property(nonatomic, copy) NSString *imageName;
@end
@implementation ProbeAsset @end
@interface AcceptedAsset : ProbeAsset @end
@implementation AcceptedAsset @end
@interface ProbeProvider : NSObject
@property(nonatomic, strong) id resource;
@property(nonatomic) unsigned calls;
@end
@implementation ProbeProvider
- (id)resourceNamed:(NSString *)key {
    ++_calls;
    return key.length ? _resource : nil;
}
@end
@interface ProbeNode : NSObject
@property(nonatomic, strong) id recipe;
@property(nonatomic, copy) NSArray *elements;
@property(nonatomic, strong) ProbeProvider *resourceProvider;
@end
@implementation ProbeNode @end

static ProbeImage *baseImage;
static ProbeProvider *onLayer, *onCompositor;
static unsigned originals, drawings;
static FGComposedStyle drawn;
static id Original(id object, SEL cmd, CGSize size, double scale) {
    ++originals; return baseImage;
}
CGImageRef NGCreateRimmedImage(CGImageRef src) {
    ++drawings; drawn = FGRenderRimmed; return CGImageRetain(src);
}
CGImageRef NGCreateGlassedImage(CGImageRef src) {
    ++drawings; drawn = FGRenderGlassed; return CGImageRetain(src);
}
// The independent ResourceImage entry must never render in this fixture.
CGImageRef NGCreateFlatIcon(id c, NSString *n, uint32_t a, size_t px) { abort(); }
CGImageRef NGCreateGlassIconContent(id c, NSString *n, uint32_t a, size_t px) { abort(); }

#define CHECK(e) do { if (!(e)) { \
    fprintf(stderr, "FAIL %s: %s (line %d)\n", label, #e, __LINE__); exit(1); \
} } while (0)
static void Run(const char *label, ProbeNode *scene, int mode, FGComposedStyle expected,
                int probeCount, id expectedReceiver, unsigned lookups) {
    state = (uint64_t)(mode + 1);
    probes = originals = drawings = 0;
    onLayer.calls = onCompositor.calls = 0;
    receiver = nil; drawn = FGRenderOriginal;
    id result = ComposedImage(scene, @selector(imageForSize:scale:), CGSizeMake(16, 16), 1);
    CHECK(originals == 1);
    // With no elements, skipping the probe or probing nil is equivalent.
    CHECK(probeCount < 0 ? probes <= 1 : probes == (unsigned)probeCount);
    CHECK(receiver == expectedReceiver);
    CHECK(onLayer.calls == lookups);
    CHECK(onCompositor.calls == 0);
    CHECK(drawn == expected);
    CHECK(drawings == (expected == FGRenderOriginal ? 0u : 1u));
    if (expected == FGRenderOriginal) {
        CHECK(result == baseImage);
    } else {
        CHECK(result != baseImage && [result isKindOfClass:ProbeImage.class]);
        CHECK([(ProbeImage *)result CGImage] == [baseImage CGImage]);
        CHECK([(ProbeImage *)result scale] == [baseImage scale]);
    }
    printf("ok - %s\n", label);
}

int main(void) {
    @autoreleasepool {
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, 16, 16, 8, 64, rgb, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(rgb);
        if (!ctx) return 1;
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (!cg) return 1;
        baseImage = [[ProbeImage alloc] initWithCGImage:cg scale:2];
        CGImageRelease(cg);
        FGModeToken = 1; FGImageClass = ProbeImage.class;
        FGAppRecipeClass = ProbeRecipe.class; FGResourceClass = AcceptedAsset.class;
        FGOriginalComposedImage = FGOriginalResourceImage = (IMP)Original;

        // Seed FGIndexFor's cache; type checks and FGHasStack/FGFindStack are real.
        NSObject *catalog = [NSObject new];
        NGRendition *stack = [NGRendition new];
        stack.layout = 0x3fb; stack.name = @"unit.iconstack";
        NGCatalogIndex *index = [NGCatalogIndex new]; index.renditions = @[stack];
        objc_setAssociatedObject(catalog, kFGIndexKey, index, OBJC_ASSOCIATION_RETAIN);
        AcceptedAsset *asset = [AcceptedAsset new]; asset.catalog = catalog; asset.imageName = @"unit";
        onLayer = [ProbeProvider new]; onLayer.resource = asset;
        onCompositor = [ProbeProvider new]; onCompositor.resource = asset;
        ProbeNode *scene = [ProbeNode new], *first = [ProbeNode new];
        scene.recipe = [ProbeRecipe new]; // keep recipe valid even without layers
        scene.elements = @[first]; first.resourceProvider = onLayer;
        Run("provider only on first layer", scene, 1, FGRenderRimmed, 1, first, 1);
        first.resourceProvider = nil; scene.resourceProvider = onCompositor;
        Run("provider only on compositor", scene, 1, FGRenderGlassed, 1, first, 0);
        ProbeNode *second = [ProbeNode new]; second.resourceProvider = onLayer;
        scene.elements = @[first, second];
        Run("later layer must not substitute for first", scene, 1, FGRenderGlassed, 1, first, 0);
        scene.elements = @[];
        Run("no layer, valid compositor recipe", scene, 1, FGRenderGlassed, -1, nil, 0);
        scene.elements = @[first]; first.resourceProvider = onLayer; onLayer.resource = nil;
        Run("empty resource", scene, 1, FGRenderGlassed, 1, first, 1);
        ProbeAsset *wrong = [ProbeAsset new]; wrong.catalog = catalog; wrong.imageName = asset.imageName;
        onLayer.resource = wrong;
        Run("wrong class with valid getters", scene, 1, FGRenderGlassed, 1, first, 1);
        onLayer.resource = asset; asset.imageName = @"absent";
        Run("missing stack", scene, 1, FGRenderGlassed, 1, first, 1);
        asset.imageName = @"unit";
        Run("edge only never probes", scene, 3, FGRenderRimmed, 0, nil, 0);
        Run("off never probes", scene, 2, FGRenderOriginal, 0, nil, 0);
        Run("mode zero never probes", scene, 0, FGRenderOriginal, 0, nil, 0);
        Run("invalid state never probes", scene, -1, FGRenderOriginal, 0, nil, 0);
        first.recipe = [NSObject new];
        Run("wrong first recipe never probes", scene, 1, FGRenderOriginal, 0, nil, 0);
        first.recipe = nil; FGOriginalResourceImage = NULL;
        Run("resource hook absent: no named lookup", scene, 1, FGRenderGlassed, 1, first, 0);
    }
    return 0;
}
