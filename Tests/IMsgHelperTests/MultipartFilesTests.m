#import <Foundation/Foundation.h>

// Exercise the actual multipart handler with deterministic IMCore stand-ins.
@interface IMFileTransfer : NSObject
@property NSString *guid;
@end
@implementation IMFileTransfer
@end
@interface IMChat : NSObject
@end
@implementation IMChat
@end

typedef NS_ENUM(NSInteger, IMsgOutgoingTransferKind) { IMsgOutgoingTransferKindAttachment };
static NSUInteger failures, prepared, registered, built, dispatched;
static NSUInteger failPrepare, failRegister;
static NSAttributedString *sentBody;
static NSArray *sentGuids;
static NSDictionary *errorResponse(NSInteger rid, NSString *error) { return @{@"error": error}; }
static NSDictionary *successResponse(NSInteger rid, NSDictionary *data) { return @{@"data": data}; }
static IMChat *resolveChatByGuid(NSString *guid) { return [IMChat new]; }
static BOOL pathHasSymlinkComponent(NSString *path) { return NO; }
static void debugLog(NSString *format, ...) {}
static void clearThreadContextForChat(id chat, id context) {}
static NSString *deriveThreadIdentifier(id chat, id guid, id *parent, id *item) { return nil; }
static NSString *outgoingMessageGuid(id message) { return @"single-guid"; }
static NSAttributedString *buildPlainAttributed(NSString *text, NSInteger index) {
    return [[NSAttributedString alloc] initWithString:text
        attributes:@{@"__kIMMessagePartAttributeName": @(index)}];
}
static NSAttributedString *buildFormattedAttributed(NSString *text, NSArray *format, NSInteger index) {
    return buildPlainAttributed(text, index);
}
static IMFileTransfer *prepareOutgoingTransfer(NSURL *url, NSString *filename, NSString *chat,
    IMsgOutgoingTransferKind kind, NSDictionary *metadata, NSString **active, NSString **error) {
    prepared++;
    if (prepared == failPrepare) return nil;
    IMFileTransfer *transfer = [IMFileTransfer new];
    transfer.guid = [NSString stringWithFormat:@"transfer-%lu", (unsigned long)prepared];
    return transfer;
}
static BOOL registerPreparedTransfer(IMFileTransfer *transfer, NSString **error) {
    registered++;
    return registered != failRegister;
}
static id buildIMMessage(NSAttributedString *body, id subject, id effect, id thread, id parent,
    id selected, long long type, NSRange range, id summary, NSArray *guids, BOOL audio, BOOL scan, id client) {
    built++; sentBody = body; sentGuids = guids;
    return [NSObject new];
}
static void dispatchIMMessageInChat(id chat, id message, id thread, id parent) { dispatched++; }
#import "../../Sources/IMsgHelper/Multipart.inc"

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}
static void reset(void) {
    prepared = registered = built = dispatched = failPrepare = failRegister = 0;
    sentBody = nil; sentGuids = nil;
}
int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; i++) {
            NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.jpg", (unsigned long)i]];
            [@"fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [parts addObject:@{@"file": path}];
        }
        NSDictionary *response = handleSendMultipart(1, @{@"chatGuid": @"test", @"parts": parts});
        check(response[@"data"] != nil, @"Four files succeed");
        check(prepared == 4 && registered == 4 && built == 1 && dispatched == 1,
              @"Four transfers are prepared and registered with exactly one message dispatch");
        check(sentBody.length == 4 && sentGuids.count == 4, @"One body and GUID list contain all attachments");
        for (NSUInteger i = 0; i < 4; i++) {
            NSDictionary *attrs = [sentBody attributesAtIndex:i effectiveRange:NULL];
            check([attrs[@"__kIMMessagePartAttributeName"] isEqual:@(i)], @"Attachment indexes are consecutive");
            check([attrs[@"__kIMFileTransferGUIDAttributeName"] isEqual:sentGuids[i]], @"Each run matches its transfer GUID");
            check([attrs[@"__kIMFilenameAttributeName"] isEqual:[NSString stringWithFormat:@"%lu.jpg", (unsigned long)i]], @"Each run retains its filename");
        }
        reset();
        handleSendMultipart(1, @{@"chatGuid": @"test", @"parts": @[parts[0], @{@"text": @"hi"}, parts[1]]});
        check([sentBody.string isEqual:@"\uFFFChi\uFFFC"] && dispatched == 1 && registered == 2,
              @"Mixed parts preserve order in one dispatch");
        check([[sentBody attribute:@"__kIMMessagePartAttributeName" atIndex:1 effectiveRange:NULL] isEqual:@1]
              && [[sentBody attribute:@"__kIMMessagePartAttributeName" atIndex:3 effectiveRange:NULL] isEqual:@2],
              @"Text and attachments share consecutive indexes");
        reset(); failPrepare = 4;
        response = handleSendMultipart(1, @{@"chatGuid": @"test", @"parts": parts});
        check(response[@"error"] && registered == 0 && dispatched == 0, @"Preparation failure cannot partially send");
        reset(); failRegister = 3;
        response = handleSendMultipart(1, @{@"chatGuid": @"test", @"parts": parts});
        check(response[@"error"] && dispatched == 0, @"Registration failure prevents dispatch");
        for (id invalid in @[@{@"file": @1}, @{@"file": @"relative.jpg"}, @{@"text": @"hi", @"file": @"x"},
                            @{@"file": dir}, @{@"file": @"/does-not-exist.jpg"}, NSNull.null]) {
            reset();
            response = handleSendMultipart(1, @{@"chatGuid": @"test", @"parts": @[parts[0], invalid]});
            check(response[@"error"] && prepared == 0 && dispatched == 0, @"Invalid later part fails before any transfer allocation");
        }
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
    fprintf(stderr, "MultipartFilesTests: %lu failures\n", (unsigned long)failures);
    return failures ? 1 : 0;
}
