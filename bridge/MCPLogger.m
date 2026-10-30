#import "MCPLogger.h"

@implementation MCPLogger
+ (BOOL)isDebugLoggingEnabled { return NO; }
+ (NSString *)logDirectoryPath { return @""; }
+ (NSString *)logFilePath { return @""; }
+ (NSString *)previousLogFilePath { return @""; }
+ (NSArray<NSString *> *)allLogFilePaths { return @[]; }
+ (NSString *)lastLogError { return @""; }
+ (void)log:(NSString *)format, ... { (void)format; }
+ (void)logMessage:(NSString *)message { (void)message; }
+ (BOOL)clearLogsWithError:(NSError **)error { (void)error; return YES; }
@end
