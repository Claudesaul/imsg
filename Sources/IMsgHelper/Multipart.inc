static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex);

static NSDictionary *handleSendMultipart(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSArray *parts = params[@"parts"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (![chatGuid isKindOfClass:[NSString class]] || !chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) {
        return errorResponse(requestId, @"Missing or empty parts array");
    }

    if (parts.count > 20) return errorResponse(requestId, @"Too many parts (maximum 20)");
    // Validate the complete request before allocating or registering transfers.
    for (id rawPart in parts) {
        if (![rawPart isKindOfClass:[NSDictionary class]]) {
            return errorResponse(requestId, @"Each part must be an object");
        }
        NSDictionary *part = rawPart;
        BOOL hasText = part[@"text"] != nil;
        BOOL hasFile = part[@"file"] != nil;
        if (hasText == hasFile) {
            return errorResponse(requestId, @"Each part requires exactly one of text or file");
        }
        for (NSString *key in part) {
            if (![@[@"text", @"file", @"textFormatting"] containsObject:key]) {
                return errorResponse(requestId, @"Unsupported multipart field");
            }
        }
        if (hasText) {
            if (![part[@"text"] isKindOfClass:[NSString class]] || ![part[@"text"] length]) {
                return errorResponse(requestId, @"Text parts must be non-empty strings");
            }
            if (part[@"textFormatting"] && ![part[@"textFormatting"] isKindOfClass:[NSArray class]]) {
                return errorResponse(requestId, @"textFormatting must be an array");
            }
        } else {
            NSString *path = part[@"file"];
            if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath
                || part[@"textFormatting"]) {
                return errorResponse(requestId, @"File parts require an absolute path and no formatting");
            }
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]
                || pathHasSymlinkComponent(path)
                || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
                return errorResponse(requestId, @"Attachment must be a readable regular file without symlinks");
            }
        }
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSMutableArray *transfers = [NSMutableArray array];
    NSMutableArray *transferGuids = [NSMutableArray array];
    NSInteger partIndex = 0;
    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    @try {
        for (NSDictionary *part in parts) {
            NSAttributedString *segment = nil;
            NSString *file = part[@"file"];
            if (file) {
                NSURL *url = [NSURL fileURLWithPath:file];
                NSString *filename = url.lastPathComponent;
                NSString *prepErr = nil;
                IMFileTransfer *transfer = prepareOutgoingTransfer(
                    url, filename, chatGuid, IMsgOutgoingTransferKindAttachment,
                    nil, NULL, &prepErr);
                if (!transfer || ![transfer guid].length) {
                    return errorResponse(requestId,
                        prepErr.length ? prepErr : @"Could not prepare multipart attachment transfer");
                }
                [transfers addObject:transfer];
                [transferGuids addObject:[transfer guid]];
                segment = buildAttachmentAttributed([transfer guid], filename, partIndex);
            } else {
                NSString *text = part[@"text"];
                NSArray *formatting = part[@"textFormatting"];
                segment = formatting.count > 0
                    ? buildFormattedAttributed(text, formatting, partIndex)
                    : buildPlainAttributed(text, partIndex);
            }
            [body appendAttributedString:segment];
            partIndex++;
        }

        id parentMessage = nil;
        id parentItem = nil;
        NSString *threadIdentifier = nil;
        if (selectedMessageGuid.length) {
            threadIdentifier = deriveThreadIdentifier(chat, selectedMessageGuid,
                                                      &parentMessage,
                                                      &parentItem);
            debugLog(@"handleSendMultipart: parent=%@ threadId=%@",
                     selectedMessageGuid, threadIdentifier ?: @"(none)");
        } else {
            clearThreadContextForChat(chat, nil);
        }
        id imMessage = buildIMMessage(body, subjectAttr, effectId, threadIdentifier,
                                      parentItem,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length),
                                      nil, transferGuids, NO, NO, nil);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct multipart IMMessage");
        }
        if (parentMessage
            && [imMessage respondsToSelector:@selector(setThreadOriginator:)]) {
            [imMessage performSelector:@selector(setThreadOriginator:)
                            withObject:parentMessage];
        }
        if (threadIdentifier
            && [imMessage respondsToSelector:@selector(setThreadIdentifier:)]) {
            [imMessage performSelector:@selector(setThreadIdentifier:)
                            withObject:threadIdentifier];
        }
        // Build once, then register every file before the single dispatch.
        for (IMFileTransfer *transfer in transfers) {
            NSString *registerErr = nil;
            if (!registerPreparedTransfer(transfer, &registerErr)) {
                return errorResponse(requestId,
                    registerErr.length ? registerErr : @"Could not register multipart attachment transfer");
            }
        }
        dispatchIMMessageInChat(chat, imMessage, threadIdentifier, parentItem);
        NSString *guid = outgoingMessageGuid(imMessage);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"parts_count": @(partIndex),
            @"transferGuids": transferGuids
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
}

/// Build an attachment-bearing attributed string. The placeholder is an OBJ
/// replacement character (￼) tagged with the IMCore attachment attributes
/// (`__kIMFileTransferGUIDAttributeName`, `__kIMFilenameAttributeName`,
/// `__kIMMessagePartAttributeName`, `__kIMBaseWritingDirectionAttributeName`).
/// Without these attributes Messages.app sends an empty-body message and never
/// links the attachment row in chat.db.
static NSAttributedString *buildAttachmentAttributed(NSString *transferGuid,
                                                     NSString *filename,
                                                     NSInteger partIndex) {
    NSDictionary *attrs = @{
        @"__kIMBaseWritingDirectionAttributeName": @"-1",
        @"__kIMFileTransferGUIDAttributeName": transferGuid ?: @"",
        @"__kIMFilenameAttributeName": filename ?: @"",
        @"__kIMMessagePartAttributeName": @(partIndex),
    };
    return [[NSAttributedString alloc] initWithString:@"￼" attributes:attrs];
}

static void setIntegerProperty(id object, SEL selector, NSInteger value) {
    if (!object || ![object respondsToSelector:selector]) return;
    NSMethodSignature *sig = [object methodSignatureForSelector:selector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:selector];
    [inv setTarget:object];
    [inv setArgument:&value atIndex:2];
    [inv invoke];
}


static NSAttributedString *buildCaptionedAttachmentAttributed(NSString *message,
                                                             NSArray *textFormatting,
                                                             NSString *transferGuid,
                                                             NSString *filename,
                                                             NSInteger partIndex) {
    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSInteger attachmentPartIndex = partIndex;
    if (message.length) {
        NSAttributedString *textBody = nil;
        if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
            textBody = buildFormattedAttributed(message, textFormatting, partIndex);
        } else {
            textBody = buildPlainAttributed(message, partIndex);
        }
        [body appendAttributedString:textBody];
        attachmentPartIndex = partIndex + 1;
    }
    [body appendAttributedString:buildAttachmentAttributed(transferGuid, filename,
                                                           attachmentPartIndex)];
    return body;
}
