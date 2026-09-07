//
//  OSRuntime.m  ——  私有/动态 API 安全访问层实现
//  仅保留分屏所需：图标 / 拉起 App / openURL。相册等 v0.2 遗留已移除。
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
        cache.countLimit = 300;
    });
    UIImage *hit = [cache objectForKey:bundleID];
    if (hit) return hit;

    Class uiClass = NSClassFromString(@"UIImage");
    SEL sel = OSSel("_applicationIconImageForBundleIdentifier:format:scale:");
    if (!uiClass || !sel) return nil;

    CGFloat scale = [UIScreen mainScreen].scale ?: 2.0;
    UIImage *(*iconFn)(id, SEL, NSString *, NSInteger, CGFloat) = (void *)objc_msgSend;
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

    OSEnsureSBSLaunch();
    if (g_SBSLaunch) {
        g_SBSLaunch(bundleID, NO);
        return YES;
    }

    Class fbsClass = NSClassFromString(@"FBSSystemService");
    if (!fbsClass) {
        OSLoadFramework(@"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices");
        fbsClass = NSClassFromString(@"FBSSystemService");
    }
    if (fbsClass) {
        id svc = OSMsg(fbsClass, OSSel("sharedService"));
        if (svc) {
            void (*openFn)(id, SEL, id, id, unsigned int, id) = (void *)objc_msgSend;
            openFn(svc, OSSel("openApplication:options:clientPort:withResult:"),
                   bundleID, @{}, 0, nil);
            return YES;
        }
    }
    OSLog(@"launchAppWithBundleID: 无可用通道 (%@)", bundleID);
    return NO;
}

+ (void)openURL:(NSURL *)url {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
