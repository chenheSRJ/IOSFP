//
//  OSModels.h
//  OneStepUI 的数据模型（纯值对象）
//

#import <UIKit/UIKit.h>
#import "OSCommon.h" // OSItemKind / 跨进程常量

NS_ASSUME_NONNULL_BEGIN

// ---------- 侧边栏：App ----------
@interface OSAppItem : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) BOOL pinned;
@end

// ---------- 侧边栏：快捷动作 ----------
typedef NS_ENUM(NSInteger, OSActionKind) {
    OSActionKindSearch = 0, // 文本 → Safari 搜索
    OSActionKindShare  = 1, // 调起系统分享面板
    OSActionKindMail   = 2, // 文本 → 新邮件
};

@interface OSActionItem : NSObject
@property (nonatomic, assign) OSActionKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbolName; // SF Symbol
+ (NSArray<OSActionItem *> *)allActions;
@end

// ---------- 顶部托盘：剪贴板历史条目 ----------
@interface OSClipItem : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSDate *date;
@end

// ---------- 顶部托盘：最近图片条目 ----------
@interface OSPhotoItem : NSObject
/// PHAsset（运行时对象，仅作句柄传递）
@property (nonatomic, strong) id asset;
@property (nonatomic, copy, nullable) NSString *assetID;
@property (nonatomic, strong, nullable) UIImage *thumbnail;
@end

// ---------- 拖拽载荷：从托盘拖出送往目标的内容 ----------
@interface OSDragPayload : NSObject
@property (nonatomic, assign) OSItemKind kind;        // text | image
@property (nonatomic, copy, nullable) NSString *text; // kind == text
@property (nonatomic, strong, nullable) NSData *imageData; // kind == image
@property (nonatomic, copy, nullable) NSString *imageUTI;  // kind == image，写剪贴板用
/// kind == image 且 imageData 尚缺时提供异步取图（执行层在发送前调用）
@property (nonatomic, copy, nullable) void (^imageProvider)(void (^)(NSData *_Nullable));
@property (nonatomic, copy) NSString *sourceTitle;    // 如「剪贴板」「相册」
@end

NS_ASSUME_NONNULL_END
