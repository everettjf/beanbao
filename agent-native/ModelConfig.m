#import "ModelConfig.h"
#import <fcntl.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const BBSettingsDirectory = @"/var/mobile/Library/Application Support/BeanBao";
static NSString *const BBSettingsPath = @"/var/mobile/Library/Application Support/BeanBao/model.json";

static BOOL BBProviderValid(NSString *provider) {
    return [@[@"claude", @"openai", @"compatible"] containsObject:provider];
}

NSString *BBModelProviderName(NSString *provider) {
    return @{@"claude": @"Claude", @"openai": @"OpenAI",
             @"compatible": @"Compatible API"}[provider] ?: @"Claude";
}

static NSDictionary *BBDefaults(void) {
    return @{@"provider": @"claude", @"profiles": @{
        @"claude": @{@"model": @"claude-sonnet-5-5"},
        @"openai": @{@"model": @"gpt-6.1-sol"},
        @"compatible": @{@"model": @"", @"endpoint": @""}}};
}

static NSData *BBReadPrivateFile(NSString *path, NSUInteger limit) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 077) || info.st_size <= 0 || info.st_size > (off_t)limit) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)info.st_size];
    uint8_t chunk[512];
    while (data.length <= limit) {
        ssize_t count = read(fd, chunk, sizeof(chunk));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { close(fd); return nil; }
        if (!count) break;
        [data appendBytes:chunk length:(NSUInteger)count];
    }
    close(fd);
    return data.length <= limit ? data : nil;
}

NSDictionary *BBModelLoad(void) {
    NSDictionary *defaults = BBDefaults();
    NSData *data = BBReadPrivateFile(BBSettingsPath, 8192);
    if (!data) return defaults;
    NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![saved isKindOfClass:NSDictionary.class] || !BBProviderValid(saved[@"provider"]) ||
        ![saved[@"profiles"] isKindOfClass:NSDictionary.class]) return defaults;
    NSMutableDictionary *profiles = [defaults[@"profiles"] mutableCopy];
    for (NSString *provider in @[@"claude", @"openai", @"compatible"]) {
        NSDictionary *entry = saved[@"profiles"][provider];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *model = entry[@"model"];
        NSString *endpoint = entry[@"endpoint"];
        if (![model isKindOfClass:NSString.class] || model.length > 120) continue;
        if (endpoint && (![endpoint isKindOfClass:NSString.class] || endpoint.length > 500)) continue;
        profiles[provider] = endpoint ? @{@"model": model, @"endpoint": endpoint} : @{@"model": model};
    }
    return @{@"provider": saved[@"provider"], @"profiles": profiles};
}

NSDictionary *BBModelProfile(NSDictionary *config, NSString *provider) {
    NSDictionary *entry = config[@"profiles"][provider];
    return [entry isKindOfClass:NSDictionary.class] ? entry : BBDefaults()[@"profiles"][provider];
}

static NSString *BBKeyPath(NSString *provider) {
    NSString *name = @{@"claude": @"claude.key", @"openai": @"openai.key",
                       @"compatible": @"compatible.key"}[provider];
    return name ? [BBSettingsDirectory stringByAppendingPathComponent:name] : nil;
}

NSString *BBModelReadKey(NSString *provider) {
    if (!BBProviderValid(provider)) return nil;
    NSData *data = BBReadPrivateFile(BBKeyPath(provider), 4096);
    if (!data && [provider isEqualToString:@"claude"])
        data = BBReadPrivateFile(@"/var/mobile/Library/Caches/BeanBao/claude.key", 4096);
    NSString *key = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!key || key.length < 8 || key.length > 4000 ||
        [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return nil;
    return key;
}

static BOOL BBWritePrivateFile(NSString *path, NSData *data) {
    NSString *temporary = [path stringByAppendingFormat:@".tmp.%@", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); unlink(temporary.fileSystemRepresentation); return NO; }
        cursor += count; remaining -= (NSUInteger)count;
    }
    BOOL okay = !fchmod(fd, 0600) && !fsync(fd);
    close(fd);
    if (!okay || rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation)) {
        unlink(temporary.fileSystemRepresentation); return NO;
    }
    return YES;
}

BOOL BBModelSave(NSString *provider, NSString *model, NSString *endpoint,
                 NSString *newKey, NSString **error) {
    if (!BBProviderValid(provider)) { if (error) *error = @"Choose a model service"; return NO; }
    model = [model stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!model.length || model.length > 120 ||
        [model rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        if (error) *error = @"Enter a valid model name"; return NO;
    }
    endpoint = [endpoint stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([provider isEqualToString:@"compatible"]) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:endpoint];
        if (endpoint.length > 500 || ![parts.scheme.lowercaseString isEqualToString:@"https"] ||
            !parts.host.length || parts.user || parts.password || parts.query || parts.fragment) {
            if (error) *error = @"Compatible APIs require an HTTPS endpoint without credentials or query parameters"; return NO;
        }
    }
    if (newKey.length && (newKey.length < 8 || newKey.length > 4000 ||
        [newKey rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)) {
        if (error) *error = @"Invalid API key"; return NO;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:BBSettingsDirectory
                             withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil]) {
        if (error) *error = @"Could not create the local settings directory"; return NO;
    }
    struct stat info = {0};
    if (lstat(BBSettingsDirectory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || chmod(BBSettingsDirectory.fileSystemRepresentation, 0700)) {
        if (error) *error = @"Settings directory permissions are unsafe"; return NO;
    }
    NSMutableDictionary *profiles = [BBModelLoad()[@"profiles"] mutableCopy];
    profiles[provider] = [provider isEqualToString:@"compatible"] ?
        @{@"model": model, @"endpoint": endpoint} : @{@"model": model};
    NSDictionary *config = @{@"provider": provider, @"profiles": profiles};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
    if (!encoded || encoded.length > 8192) { if (error) *error = @"Invalid model settings"; return NO; }
    if (newKey.length && !BBWritePrivateFile(BBKeyPath(provider), [newKey dataUsingEncoding:NSUTF8StringEncoding])) {
        if (error) *error = @"Could not save the API key"; return NO;
    }
    if (!BBWritePrivateFile(BBSettingsPath, encoded)) {
        if (error) *error = @"Could not save model settings"; return NO;
    }
    return YES;
}
