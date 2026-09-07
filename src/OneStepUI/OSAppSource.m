//
//  OSAppSource.m
//  已安装 App 枚举（LSApplicationWorkspace 优先，SBApplicationController 兜底）。
//  仅收集元数据；图标由 UI 层按需经 OSRuntime.iconForBundleID: 惰性加载。
//

#import "OSAppSource.h"
#import "OSModels.h"
#import "OSRuntime.h"
#import "OSCommon.h"

@implementation OSAppSource {
    NSArray<OSAppItem *> *_apps;
}

+ (instancetype)shared {
    static OSAppSource *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSAppSource alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _apps = @[];
        [self refresh];
    }
    return self;
}

- (NSArray<OSAppItem *> *)apps {
    return _apps;
}

static BOOL OSIsExcludedApp(NSString *bundleID) {
    static NSSet *deny = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        deny = [NSSet setWithArray:@[
            @"com.apple.springboard",   // 桌面自身
            @"com.apple.PurpleBuddy",   // 激活向导
            @"com.apple.webapp",        // WebClip 壳
        ]];
    });
    return bundleID == nil || [deny containsObject:bundleID];
}

// 用 performSelector 走运行时，避免编译期依赖私有类
static NSDictionary<NSString *, NSString *> *OSAppDictionary(id proxy) {
    if (!proxy) return nil;
    NSString *bid = OSMsg(proxy, OSSel("bundleIdentifier"));
    if (!bid) bid = OSMsg(proxy, OSSel("applicationIdentifier"));
    NSString *name = OSMsg(proxy, OSSel("localizedName"));
    if (!bid || !name) return nil;
    return @{ @"bid" : bid, @"name" : name };
}

- (void)refresh {
    NSMutableArray<OSAppItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // 渠道 1：LSApplicationWorkspace
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = wsClass ? OSMsg(wsClass, OSSel("defaultWorkspace")) : nil;
    if (workspace) {
        NSArray *proxies = OSMsg(workspace, OSSel("allInstalledApplications"));
        for (id proxy in proxies) {
            NSDictionary *d = OSAppDictionary(proxy);
            if (!d || OSIsExcludedApp(d[@"bid"])) continue;
            if ([seen containsObject:d[@"bid"]]) continue;
            [seen addObject:d[@"bid"]];
            OSAppItem *it = [OSAppItem new];
            it.bundleID = d[@"bid"];
            it.displayName = d[@"name"];
            [items addObject:it];
        }
    } else {
        // 渠道 2：SBApplicationController（SpringBoard 自身 framework）
        Class ctlClass = NSClassFromString(@"SBApplicationController");
        id ctl = ctlClass ? OSMsg(ctlClass, OSSel("sharedInstance")) : nil;
        NSDictionary *apps = ctl ? OSMsg(ctl, OSSel("applications")) : nil;
        for (id app in [apps allValues]) {
            NSString *bid = OSMsg(app, OSSel("bundleIdentifier"));
            NSString *name = OSMsg(app, OSSel("displayName"));
            if (!bid || !name || OSIsExcludedApp(bid)) continue;
            if ([seen containsObject:bid]) continue;
            [seen addObject:bid];
            OSAppItem *it = [OSAppItem new];
            it.bundleID = bid;
            it.displayName = name;
            [items addObject:it];
        }
    }

    // 固定应用优先，其余按显示名排序
    NSSet<NSString *> *pinned = [NSSet setWithArray:OSPinnedBundleIDs()];
    for (OSAppItem *it in items) it.pinned = [pinned containsObject:it.bundleID];
    [items sortUsingComparator:^NSComparisonResult(OSAppItem *a, OSAppItem *b) {
        if (a.pinned != b.pinned) return a.pinned ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedStandardCompare:b.displayName];
    }];

    _apps = items;
    OSLog(@"OSAppSource: 共 %lu 个应用", (unsigned long)_apps.count);
}

@end
