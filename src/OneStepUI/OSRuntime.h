//
//  OSRuntime.h  ——  OneStep Split 私有/动态 API 安全访问层
//
//  原则：不链接私有 framework，全部运行时 dlopen / NSClassFromString /
//  objc_msgSend 调用；任一私有 API 失效只退化对应功能，不影响整体加载。
//

#ifndef OSRuntime_h
#define OSRuntime_h

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ---------- objc_msgSend 精简封装 ----------
NS_INLINE id OSMsg(id _Nullable obj, SEL sel) {
    return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
}
NS_INLINE id OSMsg1(id _Nullable obj, SEL sel, id _Nullable p1) {
    return ((id(*)(id, SEL, id))objc_msgSend)(obj, sel, p1);
}
NS_INLINE id OSMsg2(id _Nullable obj, SEL sel, id _Nullable p1, id _Nullable p2) {
    return ((id(*)(id, SEL, id, id))objc_msgSend)(obj, sel, p1, p2);
}
NS_INLINE NSInteger OSMsgInt0(id _Nullable obj, SEL sel) {
    return ((NSInteger(*)(id, SEL))objc_msgSend)(obj, sel);
}
NS_INLINE BOOL OSMsgBool1(id _Nullable obj, SEL sel, id _Nullable p1) {
    return ((BOOL(*)(id, SEL, id))objc_msgSend)(obj, sel, p1);
}
NS_INLINE SEL OSSel(const char *name) { return sel_registerName(name); }

/// 读取对象实例变量（对象类型）——私有对象遍历用
NS_INLINE id OSIvarGet(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    void *ptr = (__bridge void *)obj;
    return (__bridge id)(*(void **)((char *)ptr + ivar_getOffset(ivar)));
}

/// 确保动态库已加载（幂等），失败返回 NULL
void *OSLoadFramework(NSString *path);

@interface OSRuntime : NSObject

/// App 图标（缓存）；失败 nil
+ (nullable UIImage *)iconForBundleID:(NSString *)bundleID;

/// 拉起 App：SBSLaunchApplicationWithIdentifier → FBSSystemService → scheme
+ (BOOL)launchAppWithBundleID:(NSString *)bundleID;

/// 打开 URL
+ (void)openURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

#endif /* OSRuntime_h */
