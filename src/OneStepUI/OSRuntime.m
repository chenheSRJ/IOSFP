//
//  OSRuntime.m
//  私有/动态 API 安全访问层实现。
//
//  所有符号通过 dlopen / NSClassFromString / sel_registerName 解析，
//  避免对私有 framework 的编译期链接依赖。
//

#import "OSRuntime.h"
#import "OSCommon.h"
#import <dlfcn.h>

// ============================================================================
// framework 动态加载（缓存 handle）
// ============================================================================
void *OSLoadFramework(NSString *path) {
    static NSMutableDictionary<NSString *, NSValue *> *handles = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handles = [NSMutableDictionary dictionary];
    });

    NSValue *cached = handles[path];
    if (cached) return cached.pointerValue;
    void *h = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    handles[path] = [NSValue valueWithPointer:h];
    return h;
}

static Class OSPhotosClass(void) {
    Class cls = NSClassFromString(@"PHPhotoLibrary");
    if (!cls) {
        OSLoadFramework(@"/System/Library/Frameworks/Photos.framework/Photos");
        cls = NSClassFromString(@"PHPhotoLibrary");
    }
    return cls;
}

@implementation OSRuntime

// ============================================================================
// App 图标
// ============================================================================
+ (UIImage *)iconForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 400;
    });
    UIImage *hit = [cache objectForKey:bundleID];
    if (hit) return hit;

    Class uiClass = NSClassFromString(@"UIImage");
    SEL sel = OSSel("_applicationIconImageForBundleIdentifier:format:scale:");
    if (!uiClass || !sel) return nil;

    CGFloat scale = [UIScreen mainScreen].scale ?: 2.0;
    UIImage *(*iconFn)(id, SEL, NSString *, NSInteger, CGFloat) = (void *)objc_msgSend;
    // format 语义随系统有变动：依次尝试常见取值，取到即用
    for (NSInteger fmt = 0; fmt <= 3; fmt++) {
        UIImage *img = iconFn(uiClass, sel, bundleID, fmt, scale);
        if (img) {
            [cache setObject:img forKey:bundleID];
            return img;
        }
    }
    return nil;
}

// ============================================================================
// 拉起 App
// ============================================================================
typedef void (*SBSLaunchFn)(NSString *, BOOL);
static SBSLaunchFn g_SBSLaunch = NULL;
static BOOL g_triedSBS = NO;

static void OSEnsureSBSLaunch(void) {
    if (g_triedSBS) return;
    g_triedSBS = YES;
    void *h = OSLoadFramework(@"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices");
    if (h) {
        g_SBSLaunch = (SBSLaunchFn)dlsym(h, "SBSLaunchApplicationWithIdentifier");
    }
}

+ (BOOL)launchAppWithBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return NO;

    // 1) SBSLaunchApplicationWithIdentifier（SpringBoardServices，越狱社区长期稳定）
    OSEnsureSBSLaunch();
    if (g_SBSLaunch) {
        g_SBSLaunch(bundleID, NO);
        return YES;
    }

    // 2) FBSSystemService（FrontBoardServices）
    Class fbsClass = NSClassFromString(@"FBSSystemService");
    if (!fbsClass) {
        OSLoadFramework(@"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices");
        fbsClass = NSClassFromString(@"FBSSystemService");
    }
    if (fbsClass) {
        id svc = OSMsg(fbsClass, OSSel("sharedService"));
        if (svc) {
            // -openApplication:options:clientPort:withResult:
            void (*openFn)(id, SEL, id, id, unsigned int, id) = (void *)objc_msgSend;
            openFn(svc, OSSel("openApplication:options:clientPort:withResult:"),
                   bundleID, @{}, 0, nil);
            return YES;
        }
    }

    // 3) 开放 URL scheme（最后的兜底）
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass) {
        id proxy = OSMsg1(proxyClass, OSSel("applicationProxyForIdentifier:"), bundleID);
        NSArray *schemes = proxy ? OSMsg(proxy, OSSel("URLSchemes")) : nil;
        if ([schemes isKindOfClass:NSArray.class] && schemes.firstObject) {
            NSString *scheme = schemes.firstObject;
            NSURL *url = [NSURL URLWithString:[scheme stringByAppendingString:@"://"]];
            if (url) {
                [self openURL:url];
                return YES;
            }
        }
    }
    OSLog(@"launchAppWithBundleID: 无可用通道 (%@)", bundleID);
    return NO;
}

+ (void)openURL:(NSURL *)url {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

// ============================================================================
// 相册（Photos，运行时加载）
// ============================================================================
+ (NSInteger)photoAuthorizationStatus {
    Class cls = OSPhotosClass();
    if (!cls) return -1;
    return OSMsgInt0(cls, OSSel("authorizationStatus"));
}

+ (void)requestPhotoAuthorization:(void (^)(NSInteger status))completion {
    Class cls = OSPhotosClass();
    if (!cls) {
        if (completion) completion(-1);
        return;
    }
    typedef void (*ReqAuthFn)(id, SEL, void (^)(NSInteger));
    ReqAuthFn fn = (ReqAuthFn)objc_msgSend;
    void (^copied)(NSInteger) = [completion copy];
    fn(cls, OSSel("requestAuthorization:"), ^(NSInteger status) {
        if (copied) copied(status);
    });
}

+ (NSArray<id> *)recentPhotoAssets:(NSUInteger)count {
    Class photoLib = OSPhotosClass();
    Class assetCls = NSClassFromString(@"PHAsset");
    if (!photoLib || !assetCls) return @[];

    NSInteger st = OSMsgInt0(photoLib, OSSel("authorizationStatus"));
    // 3 = 完全允许，4 = 仅所选照片（iOS 14+）
    if (st != 3 && st != 4) return @[];

    Class optCls = NSClassFromString(@"PHFetchOptions");
    if (!optCls) return @[];

    id options = [[optCls alloc] init];
    id sortDesc = [NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO];
    OSMsg1(options, OSSel("setSortDescriptors:"), @[ sortDesc ]);

    id result = OSMsg1(assetCls, OSSel("fetchAssetsWithOptions:"), options);
    if (!result) return @[];
    NSInteger total = OSMsgInt0(result, OSSel("count"));
    if (total <= 0) return @[];

    NSMutableArray *out = [NSMutableArray array];
    NSUInteger n = MIN((NSUInteger)total, count);
    for (NSUInteger i = 0; i < n; i++) {
        id asset = OSMsg1(result, OSSel("objectAtIndex:"), @(i));
        if (asset) [out addObject:asset];
    }
    return out;
}

+ (void)imageDataForAsset:(id)asset completion:(void (^)(NSData *data))completion {
    void (^copied)(NSData *) = [completion copy];
    if (!asset) {
        if (copied) copied(nil);
        return;
    }
    Class mgrCls = NSClassFromString(@"PHImageManager");
    if (!mgrCls) {
        OSLoadFramework(@"/System/Library/Frameworks/Photos.framework/Photos");
        mgrCls = NSClassFromString(@"PHImageManager");
    }
    id mgr = mgrCls ? OSMsg(mgrCls, OSSel("defaultManager")) : nil;
    if (!mgr) {
        if (copied) copied(nil);
        return;
    }

    typedef void (*ImgDataFn)(id, SEL, id, id, void (^)(NSData *, NSString *, NSInteger, NSDictionary *));
    ImgDataFn fn = (ImgDataFn)objc_msgSend;
    fn(mgr, OSSel("requestImageDataForAsset:options:resultHandler:"), asset, nil,
       ^(NSData *data, NSString *uti, NSInteger orientation, NSDictionary *info) {
           if (copied) copied(data);
       });
}

+ (void)thumbnailForAsset:(id)asset targetSize:(CGSize)size completion:(void (^)(UIImage *image))completion {
    void (^copied)(UIImage *) = [completion copy];
    if (!asset) {
        if (copied) copied(nil);
        return;
    }
    NSString *key = OSMsg(asset, OSSel("localIdentifier"));
    static NSCache *thumbCache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        thumbCache = [[NSCache alloc] init];
        thumbCache.countLimit = 120;
    });
    if (key) {
        UIImage *hit = [thumbCache objectForKey:key];
        if (hit) {
            if (copied) copied(hit);
            return;
        }
    }

    Class mgrCls = NSClassFromString(@"PHImageManager");
    if (!mgrCls) {
        OSLoadFramework(@"/System/Library/Frameworks/Photos.framework/Photos");
        mgrCls = NSClassFromString(@"PHImageManager");
    }
    id mgr = mgrCls ? OSMsg(mgrCls, OSSel("defaultManager")) : nil;
    if (!mgr) {
        if (copied) copied(nil);
        return;
    }

    // -requestImageForAsset:targetSize:contentMode:options:resultHandler:
    // contentMode: 1 = AspectFill
    typedef void (*ImgFn)(id, SEL, id, CGSize, NSInteger, id, void (^)(UIImage *, NSDictionary *));
    ImgFn fn = (ImgFn)objc_msgSend;
    fn(mgr, OSSel("requestImageForAsset:targetSize:contentMode:options:resultHandler:"),
       asset, size, 1, nil,
       ^(UIImage *image, NSDictionary *info) {
           if (image && key) [thumbCache setObject:image forKey:key];
           if (copied) copied(image);
       });
}

@end
