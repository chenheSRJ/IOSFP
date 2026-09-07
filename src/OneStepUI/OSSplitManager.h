//
//  OSSplitManager.h  ——  OneStep Split 主控（SpringBoard 内单例）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSSplitManager : NSObject

+ (instancetype)shared;

/// 幂等启动（SpringBoard 就绪后调用）
- (void)start;

@end

NS_ASSUME_NONNULL_END
