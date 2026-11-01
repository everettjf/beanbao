#import "VoiceIPC.h"
#import <fcntl.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *BBVoicePath(NSString *kind) {
    if (![@[@"start", @"ready", @"stop", @"result", @"cancel"] containsObject:kind ?: @""]) return nil;
    return [@"/var/mobile/Library/Caches/BeanBao/overlay-voice." stringByAppendingString:kind];
}

BOOL BBVoiceValidSession(NSString *sessionID) {
    if (![sessionID isKindOfClass:NSString.class] || sessionID.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:sessionID];
    return uuid && [uuid.UUIDString isEqualToString:sessionID];
}

BOOL BBVoiceWrite(NSString *kind, NSDictionary *payload) {
    NSString *path = BBVoicePath(kind);
    if (!path || !BBVoiceValidSession(payload[@"session"]) ||
        ![NSJSONSerialization isValidJSONObject:payload]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data || data.length > 4096) return NO;
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    BOOL ok = !fchmod(fd, 0600) && (geteuid() != 0 || !fchown(fd, 501, 501));
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (ok && remaining) {
        ssize_t wrote = write(fd, cursor, remaining);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { ok = NO; break; }
        cursor += wrote;
        remaining -= (NSUInteger)wrote;
    }
    if (ok) ok = fsync(fd) == 0;
    close(fd);
    if (ok) ok = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(temporary.fileSystemRepresentation);
    return ok;
}

NSDictionary *BBVoiceRead(NSString *kind) {
    NSString *path = BBVoicePath(kind);
    if (!path) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != 501 ||
        (info.st_mode & 077) || info.st_size <= 0 || info.st_size > 4096) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    uint8_t *cursor = data.mutableBytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = read(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        cursor += count;
        remaining -= (NSUInteger)count;
    }
    close(fd);
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *payload = [value isKindOfClass:NSDictionary.class] ? value : nil;
    return BBVoiceValidSession(payload[@"session"]) ? payload : nil;
}

void BBVoiceRemove(NSString *kind) {
    NSString *path = BBVoicePath(kind);
    if (path) unlink(path.fileSystemRepresentation);
}
