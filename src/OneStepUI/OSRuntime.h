//
//  OSRuntime.h
//  私有/动态 API 安全访问层。
//
//  原则：不链接任何私有 framework，全部运行时 dlopen / NSClassFromString /
//  objc_msgSend 调用 —— 这样即使某私有 API 在新系统改名，也只是该功能退化，
//  不会导致整包加载失败。集中放置便于「真机验证清单」逐条核对（见 README）。
//

#ifndef OSRuntime_h
#define OSRuntime_h

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ---------- objc_msgSend 精简封装（ARC 安全：参数/返回均为 ObjC 对象或基本类型） ----------
NS_INLINE id OSMsg(id obj, SEL sel) {
    return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
}
NS_INLINE id OSMsg1(id obj, SEL sel, id p1) {
    return ((id(*)(id, SEL, id))objc_msgSend)(obj, sel, p1);
}
NS_INLINE id OSMsg2(id obj, SEL sel, id p1, id p2) {
    return ((id(*)(id, SEL, id, id))objc_msgSend)(obj, sel, p1, p2);
}
NS_INLINE NSInteger OSMsgInt0(id obj, SEL sel) {
    return ((NSInteger(*)(id, SEL))objc_msgSend)(obj, sel);
}
NS_INLINE BOOL OSMsgBool1(id obj, SEL sel, id p1) {
    return ((BOOL(*)(id, SEL, id))objc_msgSend)(obj, sel, p1);
}
NS_INLINE SEL OSSel(const char *name) { return sel_registerName(name); }

/// 确保动态库已加载（幂等，返回 dlopen handle，失败返回 NULL）
void *OSLoadFramework(NSString *path);

@interface OSRuntime : NSObject

// ---------- App 图标 ----------
/// 返回 App 图标（NSCache 缓存）；失败返回 nil（调用方自绘占位）。
+ (nullable UIImage *)iconForBundleID:(NSString *)bundleID;

// ---------- 拉起 App ----------
/// 按优先级：SBSLaunchApplicationWithIdentifier → FBSSystemService → 开放 URL scheme。
/// 返回 YES 表示有可用通道（并非保证启动成功）。
+ (BOOL)launchAppWithBundleID:(NSString *)bundleID;

/// 打开 URL（mailto:/sms:/https: 等）。SB 进程内直接 openURL。
+ (void)openURL:(NSURL *)url;

// ---------- 相册（Photos，运行时加载） ----------
/// 0=未决定 1=受限 2=拒绝 3=允许 4=仅部分(iOS14+)。未加载框架返回 -1。
+ (NSInteger)photoAuthorizationStatus;
+ (void)requestPhotoAuthorization:(void (^)(NSInteger status))completion;
/// 最近图片 asset 列表（id 对象，来自 PHFetchResult）。失败返回空数组。
+ (NSArray<id> *)recentPhotoAssets:(NSUInteger)count;
/// 异步取原图数据（供拖放发送；主线程安全，回调在任意队列，需回主线程更新 UI）。
+ (void)imageDataForAsset:(id)asset completion:(void (^)(NSData *_Nullable data))completion;
/// 异步取缩略图（供托盘展示，内部缓存；回调任意队列）。
+ (void)thumbnailForAsset:(id)asset targetSize:(CGSize)size completion:(void (^)(UIImage *_Nullable image))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* OSRuntime_h */
