#pragma mark - Inbound Event Observers

/// Whether the other side is typing in `chat`: the chat's last item is an
/// incoming typing indicator that hasn't been cancelled.
static BOOL incomingTyping(id chat) {
    if ([chat respondsToSelector:@selector(isLastMessageTypingIndicator)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isLastMessageTypingIndicator));
    }
    if (![chat respondsToSelector:@selector(lastMessage)]) return NO;
    id last = [chat performSelector:@selector(lastMessage)];
    if (![last respondsToSelector:@selector(isTypingMessage)]) return NO;
    BOOL typing = ((BOOL (*)(id, SEL))objc_msgSend)(last, @selector(isTypingMessage));
    BOOL cancel = [last respondsToSelector:@selector(isCancelTypingMessage)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(last, @selector(isCancelTypingMessage));
    BOOL mine = [last respondsToSelector:@selector(isFromMe)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(last, @selector(isFromMe));
    return typing && !cancel && !mine;
}

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
static void registerEventObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Typing from the other side shows up as a typing item at the end of the
    // chat. IMCore posts the change under the `__k` names (the bare
    // "IMChatItemsDidChangeNotification" never fires), and its inserted
    // items are an index set, not the items, so read the chat's own state
    // after each change and emit started-typing / stopped-typing on edges.
    static NSMutableDictionary<NSString *, NSNumber *> *typingByChat;
    typingByChat = [NSMutableDictionary dictionary];
    void (^check)(NSNotification *) = ^(NSNotification *note) {
        @autoreleasepool {
            id chat = note.object;
            if (!chat || ![chat respondsToSelector:@selector(guid)]) return;
            NSString *chatGuid = [chat performSelector:@selector(guid)];
            if (![chatGuid isKindOfClass:[NSString class]]) return;
            BOOL typing = incomingTyping(chat);
            BOOL was = [typingByChat[chatGuid] boolValue];
            if (typing == was) return;
            typingByChat[chatGuid] = @(typing);
            debugLog(@"typing %@ chat=%@ via=%@", typing ? @"started" : @"stopped", chatGuid, note.name);
            appendEvent(@{
                @"event": typing ? @"started-typing" : @"stopped-typing",
                @"data": @{ @"chatGuid": chatGuid }
            });
        }
    };
    for (NSString *name in @[@"__kIMChatItemsDidChangeNotification",
                             @"__kIMChatMessageReceivedNotification"]) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:check];
    }

    // Account aliases removed (e.g., user removed an iMessage email).
    [nc addObserverForName:@"__kIMAccountAliasesRemovedNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        appendEvent(@{
            @"event": @"aliases-removed",
            @"data": note.userInfo ?: @{}
        });
    }];

    NSLog(@"[imsg-bridge] Event observers registered");
}

