//
//  OSDragController.m
//  实现见头文件。浮层直接挂在 overlay window 上，跟手更新中心点。
//

#import "OSDragController.h"
#import "OSModels.h"

@implementation OSDragController {
    UIWindow *_hostWindow;
    UIView *_floatView;
    CGRect _originFrame;
    OSDragPayload *_payload;
    id _currentTarget;
}

- (BOOL)isDragging {
    return _floatView != nil || _payload != nil;
}

- (void)startDragWithPayload:(OSDragPayload *)payload
                    snapshot:(UIView *)snapshot
               atWindowPoint:(CGPoint)p
                    inWindow:(UIWindow *)window {
    [self cancelDrag]; // 兜底清理
    _payload = payload;
    _hostWindow = window;

    if (snapshot) {
        _originFrame = snapshot.frame;
        _floatView = snapshot;
        _floatView.layer.shadowColor = [UIColor blackColor].CGColor;
        _floatView.layer.shadowOpacity = 0.35;
        _floatView.layer.shadowRadius = 10;
        _floatView.layer.shadowOffset = CGSizeMake(0, 6);
        _floatView.userInteractionEnabled = NO;
        [window addSubview:_floatView];
        [self _moveFloatToPoint:p];
        _floatView.transform = CGAffineTransformMakeScale(1.10, 1.10);
    }
}

- (void)updateDragAtWindowPoint:(CGPoint)p {
    [self _moveFloatToPoint:p];
    if (!_hostWindow) return;

    id target = [self.delegate dragControllerDropTargetAtWindowPoint:p];
    if (target != _currentTarget) {
        _currentTarget = target;
        [self.delegate dragControllerHighlightTarget:target];
    }
}

- (void)endDragAtWindowPoint:(CGPoint)p {
    [self _moveFloatToPoint:p];
    BOOL hasTarget = (_currentTarget != nil);

    if (hasTarget) {
        id target = _currentTarget;
        [self.delegate dragControllerHighlightTarget:nil];
        [self _dismissFloatAnimated:NO];
        OSDragPayload *pl = _payload;
        [self _reset];
        [self.delegate dragController:self didDropOnTarget:target payload:pl];
    } else {
        [self.delegate dragControllerDidCancel:self];
        [self cancelDrag];
    }
}

- (void)cancelDrag {
    if (_floatView) {
        UIView *fv = _floatView;
        _floatView = nil;
        [UIView animateWithDuration:0.18
                         animations:^{
                             fv.alpha = 0;
                             fv.transform = CGAffineTransformIdentity;
                         }
                         completion:^(BOOL f) {
                             [fv removeFromSuperview];
                         }];
    }
    [self.delegate dragControllerHighlightTarget:nil];
    [self _reset];
}

- (void)_moveFloatToPoint:(CGPoint)p {
    if (!_floatView) return;
    _floatView.center = p;
}

- (void)_dismissFloatAnimated:(BOOL)animated {
    if (!_floatView) return;
    UIView *fv = _floatView;
    _floatView = nil;
    void (^rm)(void) = ^{ [fv removeFromSuperview]; };
    if (!animated) {
        rm();
    } else {
        [UIView animateWithDuration:0.15 animations:^{
            fv.alpha = 0;
            fv.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL f) { rm(); }];
    }
}

- (void)_reset {
    _payload = nil;
    _hostWindow = nil;
    _currentTarget = nil;
    _floatView = nil;
}

@end
