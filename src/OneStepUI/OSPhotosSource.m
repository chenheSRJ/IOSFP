//
//  OSPhotosSource.m
//  见头文件注释。缩略图不在此层加载（由 UI 层按需异步取，见 OSPhotoCell）。
//

#import "OSPhotosSource.h"
#import "OSRuntime.h"
#import "OSCommon.h"

@implementation OSPhotosSource {
    NSArray<id> *_assets;
    NSInteger _authStatus;
}

+ (instancetype)shared {
    static OSPhotosSource *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSPhotosSource alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _assets = @[];
        _authStatus = [OSRuntime photoAuthorizationStatus];
    }
    return self;
}

- (NSArray<id> *)assets {
    return _assets;
}

- (NSInteger)authStatus {
    return _authStatus;
}

- (void)refresh {
    NSInteger st = [OSRuntime photoAuthorizationStatus];
    _authStatus = st;

    if (st == 0) { // notDetermined：先请求授权（会弹系统框，需主线程）
        dispatch_async(dispatch_get_main_queue(), ^{
            [OSRuntime requestPhotoAuthorization:^(NSInteger status) {
                self->_authStatus = status;
                [self _fetchIfAllowed];
            }];
        });
        return;
    }
    [self _fetchIfAllowed];
}

- (void)_fetchIfAllowed {
    NSInteger st = _authStatus;
    if (st == 3 || st == 4) { // 允许 / 仅部分
        _assets = [OSRuntime recentPhotoAssets:OSMaxRecentPhotos()];
    } else {
        _assets = @[];
    }
    OSLog(@"OSPhotosSource: auth=%ld assets=%lu", (long)_authStatus,
          (unsigned long)_assets.count);
    if (self.onChange) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onChange) self.onChange();
        });
    }
}

@end
