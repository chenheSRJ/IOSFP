//
//  OSUIManager.h
//  OneStep 主控（SpringBoard 进程内单例）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSUIManager : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isStarted) BOOL started;

/// 幂等启动：在 SpringBoard UI 就绪后调用
- (void)start;

/// 停止并移除浮层窗口（卸载用，一般不需要）
- (void)stop;

@end

NS_ASSUME_NONNULL_END
