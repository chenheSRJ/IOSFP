//
//  OSDiag.h  ——  OneStep 文件日志（诊断用）
//
//  手机端读不到 unified log（roothide 环境无 /usr/bin/log），诊断日志
//  改为双写：NSLog + 追加写入 /var/mobile/onestep.log，用户 cat 即得。
//

#import <Foundation/Foundation.h>

/// 双写日志（NSLog + 文件追加）
FOUNDATION_EXPORT void OSLogF(NSString *fmt, ...);

/// 重置日志文件（可选）
FOUNDATION_EXPORT void OSDiagReset(void);
