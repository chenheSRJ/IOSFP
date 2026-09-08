//
//  OSDiag.m  ——  实现见头文件。文件追加写，线程安全用互斥锁。
//

#import "OSDiag.h"
#import <stdio.h>
#import <pthread.h>

static FILE *g_fp = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void OSDiagEnsureFile(void) {
    if (g_fp) return;
    g_fp = fopen("/var/mobile/onestep.log", "a");
}

void OSLogF(NSString *fmt, ...) {
    if (fmt.length == 0) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[OneStep] %@", msg);

    pthread_mutex_lock(&g_lock);
    OSDiagEnsureFile();
    if (g_fp) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        fputs(line.UTF8String, g_fp);
        fflush(g_fp);
    }
    pthread_mutex_unlock(&g_lock);
}

void OSDiagReset(void) {
    pthread_mutex_lock(&g_lock);
    if (g_fp) { fclose(g_fp); g_fp = NULL; }
    g_fp = fopen("/var/mobile/onestep.log", "w");
    pthread_mutex_unlock(&g_lock);
}
