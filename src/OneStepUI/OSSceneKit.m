//
//  OSSceneKit.m  ——  Scene 内核实现
//
//  注：本实现仅借鉴公开讨论的通用机制（SpringBoard 场景 ivar 遍历、
//  _UISceneLayerHostContainerView 层宿主、settings.foreground 更新、每秒保活），
//  代码为独立编写，不复制任何既有实现文本。
//

#import "OSSceneKit.h"
#import "OSCommon.h"
#import "OSRuntime.h"

@implementation OSSceneKit

// ============================================================================
#pragma mark - Scene 管理器
// ============================================================================

/// 取场景管理器：优先 SBMainWorkspace.sceneManager（新系统），回退 FBSceneManager
+ (id)_sceneManager {
    Class mainWS = NSClassFromString(@"SBMainWorkspace");
    if (mainWS && [mainWS respondsToSelector:@selector(sharedInstance)]) {
        id ws = OSMsg(mainWS, OSSel("sharedInstance"));
        if (ws && [ws respondsToSelector:@selector(sceneManager)]) {
            id mgr = OSMsg(ws, OSSel("sceneManager"));
            if (mgr) return mgr;
        }
    }
    Class fbMgr = NSClassFromString(@"FBSceneManager");
    if (fbMgr && [fbMgr respondsToSelector:@selector(sharedInstance)]) {
        return OSMsg(fbMgr, OSSel("sharedInstance"));
    }
    return nil;
}

/// 在“字典值可能是 FBScene 或带 -scene 的 handle”的容器中找匹配项
+ (id)_firstMatchIn:(id)container bundleID:(NSString *)bid {
    NSArray *candidates = nil;
    if ([container isKindOfClass:NSDictionary.class]) {
        candidates = [(NSDictionary *)container allValues];
    } else if ([container respondsToSelector:@selector(allValues)]) {
        candidates = OSMsg(container, OSSel("allValues"));
    } else if ([container respondsToSelector:@selector(allObjects)]) {
        candidates = OSMsg(container, OSSel("allObjects"));
    }
    for (id obj in candidates) {
        if (![obj isKindOfClass:NSObject.class]) continue;
        NSString *sid = nil;
        if ([obj respondsToSelector:@selector(identifier)]) {
            sid = OSMsg(obj, OSSel("identifier"));
        }
        if (sid && [sid isKindOfClass:NSString.class] &&
            [sid rangeOfString:bid].location != NSNotFound) {
            return obj; // 可能是 FBScene
        }
        // 可能是 handle/entity：再取 -scene
        if ([obj respondsToSelector:@selector(scene)]) {
            id scene = OSMsg(obj, OSSel("scene"));
            if (scene && [scene respondsToSelector:@selector(identifier)]) {
                sid = OSMsg(scene, OSSel("identifier"));
                if (sid && [sid isKindOfClass:NSString.class] &&
                    [sid rangeOfString:bid].location != NSNotFound) {
                    return scene;
                }
            }
        }
    }
    return nil;
}

// ============================================================================
#pragma mark - FBScene 查找
// ============================================================================

+ (id)fbSceneForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    id manager = [self _sceneManager];
    if (!manager) {
        OSLog(@"[SceneKit] 无场景管理器");
        return nil;
    }

    // 1) 管理器与 _workspace 上的常见字典 ivar
    NSArray *rootObjs = @[ manager ];
    id ws = OSIvarGet(manager, "_workspace");
    if (ws) rootObjs = [rootObjs arrayByAddingObject:ws];
    for (id root in rootObjs) {
        for (NSString *ivarName in @[@"_scenesByID", @"_allScenesByID",
                                     @"_scenesByIdentifier", @"_scenes"]) {
            id dict = OSIvarGet(root, ivarName.UTF8String);
            if ([dict isKindOfClass:NSDictionary.class]) {
                id hit = [self _firstMatchIn:dict bundleID:bundleID];
                if (hit) {
                    // 确保返回 FBScene（若命中 handle 则展开）
                    if ([hit respondsToSelector:@selector(layerManager)] ||
                        [hit respondsToSelector:@selector(settings)]) {
                        return hit;
                    }
                    if ([hit respondsToSelector:@selector(scene)]) {
                        id scene = OSMsg(hit, OSSel("scene"));
                        if (scene) return scene;
                    }
                }
            }
        }
    }

    // 2) allScenes 枚举
    if ([manager respondsToSelector:@selector(allScenes)]) {
        for (id scene in OSMsg(manager, OSSel("allScenes"))) {
            NSString *sid = [scene respondsToSelector:@selector(identifier)]
                ? OSMsg(scene, OSSel("identifier")) : nil;
            if (sid && [sid isKindOfClass:NSString.class] &&
                [sid rangeOfString:bundleID].location != NSNotFound) {
                return scene;
            }
        }
    }

    // 3) 深扫：管理器任一对象字典 ivar 里找含 bundleID 键/值
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(manager), &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == '@') {
            id value = OSIvarGet(manager, ivar_getName(ivars[i]));
            if ([value isKindOfClass:NSDictionary.class]) {
                id hit = [self _firstMatchIn:value bundleID:bundleID];
                if (hit) { free(ivars); return hit; }
            }
        }
    }
    if (ivars) free(ivars);

    OSLog(@"[SceneKit] 未找到 scene: %@", bundleID);
    return nil;
}

// ============================================================================
#pragma mark - Layer Host（浮窗内容）
// ============================================================================

+ (UIView *)layerHostViewForBundleID:(NSString *)bundleID frame:(CGRect)frame {
    id scene = [self fbSceneForBundleID:bundleID];
    if (!scene) {
        OSLog(@"[SceneKit] host 失败：无 scene (%@)", bundleID);
        return nil;
    }
    Class cls = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!cls) {
        OSLog(@"[SceneKit] host 失败：无 _UISceneLayerHostContainerView");
        return nil;
    }

    UIView *container = nil;
    if ([cls instancesRespondToSelector:@selector(initWithScene:)]) {
        id (*allocFn)(id, SEL) = (void *)objc_msgSend;
        id (*initFn)(id, SEL, id) = (void *)objc_msgSend;
        id instance = allocFn(cls, OSSel("alloc"));
        if (instance) container = initFn(instance, OSSel("initWithScene:"), scene);
    }
    if (!container) return nil;
    container.frame = frame;
    container.clipsToBounds = YES;
    container.layer.cornerRadius = 16;
    OSLog(@"[SceneKit] 已为 %@ 创建 layer host", bundleID);
    return container;
}

// ============================================================================
#pragma mark - Foreground / 保活
// ============================================================================

+ (void)setForeground:(BOOL)fg forBundleID:(NSString *)bundleID {
    id scene = [self fbSceneForBundleID:bundleID];
    if (!scene) return;
    @try {
        id settings = [scene respondsToSelector:@selector(settings)]
            ? OSMsg(scene, OSSel("settings")) : nil;
        if (settings && [settings respondsToSelector:@selector(mutableCopy)]) {
            id mut = [settings mutableCopy];
            if ([mut respondsToSelector:@selector(setForeground:)]) {
                void (*sfFn)(id, SEL, BOOL) = (void *)objc_msgSend;
                sfFn(mut, OSSel("setForeground:"), fg);
                if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
                    OSMsg2(scene, OSSel("updateSettings:withTransitionContext:"), mut, nil);
                } else if ([scene respondsToSelector:
                            @selector(updateSettings:withTransitionContext:completion:)]) {
                    // 3 参：objc_msgSend 变长，用函数指针
                    void (*fn)(id, SEL, id, id, id) = (void *)objc_msgSend;
                    fn(scene, OSSel("updateSettings:withTransitionContext:completion:"),
                       mut, nil, nil);
                }
                return;
            }
        }
        OSLog(@"[SceneKit] setForeground(%@) 设置路径不可用", bundleID);
    } @catch (NSException *e) {
        OSLog(@"[SceneKit] setForeground 异常: %@", e);
    }
}

+ (void)startKeepAliveForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return;
    static NSMutableDictionary *timers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ timers = [NSMutableDictionary dictionary]; });
    @synchronized (timers) {
        NSTimer *old = timers[bundleID];
        if (old) { [old invalidate]; }
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(_keepAliveTick:)
                                                    userInfo:bundleID
                                                     repeats:YES];
        timers[bundleID] = t;
        OSLog(@"[SceneKit] keep-alive 启动: %@", bundleID);
    }
}

+ (void)stopKeepAliveForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return;
    static NSMutableDictionary *timers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ timers = [NSMutableDictionary dictionary]; });
    @synchronized (timers) {
        NSTimer *t = timers[bundleID];
        if (t) {
            [t invalidate];
            [timers removeObjectForKey:bundleID];
            OSLog(@"[SceneKit] keep-alive 停止: %@", bundleID);
        }
    }
}

+ (void)_keepAliveTick:(NSTimer *)timer {
    NSString *bid = timer.userInfo;
    if (bid.length == 0) return;
    [self setForeground:YES forBundleID:bid];
}

// ============================================================================
#pragma mark - 前台识别 / 屏幕
// ============================================================================

+ (NSString *)frontmostAppBundleID {
    Class ctlClass = NSClassFromString(@"SBApplicationController");
    id ctl = ctlClass ? OSMsg(ctlClass, OSSel("sharedInstance")) : nil;
    NSDictionary *apps = ctl ? OSMsg(ctl, OSSel("applications")) : nil;
    if (![apps isKindOfClass:NSDictionary.class]) return nil;
    for (id app in [apps allValues]) {
        BOOL fg = NO;
        if ([app respondsToSelector:@selector(isForeground)]) {
            BOOL (*fgFn)(id, SEL) = (void *)objc_msgSend;
            fg = fgFn(app, OSSel("isForeground"));
        }
        if (fg) {
            NSString *bid = OSMsg(app, OSSel("bundleIdentifier"));
            if (bid) return bid;
        }
    }
    return nil;
}

+ (CGRect)screenBounds {
    return [UIScreen mainScreen].bounds;
}

@end
