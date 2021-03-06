//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSOutgoingMessage.h"
#import "NSDate+OWS.h"
#import "OWSOutgoingSyncMessage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "ProtoBuf+OWS.h"
#import "SignalRecipient.h"
#import "TSAttachmentStream.h"
#import "TSContactThread.h"
#import "TSGroupThread.h"
#import "TextSecureKitEnv.h"
#import <YapDatabase/YapDatabase.h>
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kTSOutgoingMessageSentRecipientAll = @"kTSOutgoingMessageSentRecipientAll";

@interface TSOutgoingMessage ()

@property (atomic) TSOutgoingMessageState messageState;
@property (atomic) BOOL hasSyncedTranscript;
@property (atomic) NSString *customMessage;
@property (atomic) NSString *mostRecentFailureText;
@property (atomic) BOOL wasDelivered;
@property (atomic) NSString *singleGroupRecipient;
@property (atomic) BOOL isFromLinkedDevice;

// For outgoing, non-legacy group messages sent from this client, this
// contains the list of recipients to whom the message has been sent.
//
// This collection can also be tested to avoid repeat delivery to the
// same recipient.
@property (atomic) NSArray<NSString *> *sentRecipients;

@property (atomic) TSGroupMetaMessage groupMetaMessage;

@property (atomic) NSDictionary<NSString *, NSNumber *> *recipientDeliveryMap;

@property (atomic) NSDictionary<NSString *, NSNumber *> *recipientReadMap;

@end

#pragma mark -

@implementation TSOutgoingMessage

@synthesize sentRecipients = _sentRecipients;

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];

    if (self) {
        if (!_attachmentFilenameMap) {
            _attachmentFilenameMap = [NSMutableDictionary new];
        }
        
        // Migrate message state.
        if (_messageState == TSOutgoingMessageStateSent_OBSOLETE) {
            _messageState = TSOutgoingMessageStateSentToService;
        } else if (_messageState == TSOutgoingMessageStateDelivered_OBSOLETE) {
            _messageState = TSOutgoingMessageStateSentToService;
            _wasDelivered = YES;
        }
        if (!_sentRecipients) {
            _sentRecipients = [NSArray new];
        }
    }

    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
{
    return [self initWithTimestamp:timestamp inThread:nil];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp inThread:(nullable TSThread *)thread
{
    return [self initWithTimestamp:timestamp inThread:thread messageBody:nil];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
{
    return [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:body
                     attachmentIds:[NSMutableArray new]
                  expiresInSeconds:0];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
                    attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
{
    return [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:body
                     attachmentIds:attachmentIds
                  expiresInSeconds:0];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
                    attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                 expiresInSeconds:(uint32_t)expiresInSeconds
{
    return [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:body
                     attachmentIds:attachmentIds
                  expiresInSeconds:expiresInSeconds
                   expireStartedAt:0];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)messageBody
                   isVoiceMessage:(BOOL)isVoiceMessage
                 expiresInSeconds:(uint32_t)expiresInSeconds
{
    self = [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:messageBody
                     attachmentIds:[NSMutableArray new]
                  expiresInSeconds:expiresInSeconds
                   expireStartedAt:0];
    if (self) {
        _isVoiceMessage = isVoiceMessage;
    }

    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
                    attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                 expiresInSeconds:(uint32_t)expiresInSeconds
                  expireStartedAt:(uint64_t)expireStartedAt
{
    TSGroupMetaMessage groupMetaMessage
        = ([thread isKindOfClass:[TSGroupThread class]] ? TSGroupMessageDeliver : TSGroupMessageNone);
    return [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:body
                     attachmentIds:attachmentIds
                  expiresInSeconds:expiresInSeconds
                   expireStartedAt:expireStartedAt
                  groupMetaMessage:groupMetaMessage];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                 groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
{
    return [self initWithTimestamp:timestamp
                          inThread:thread
                       messageBody:@""
                     attachmentIds:[NSMutableArray new]
                  expiresInSeconds:0
                   expireStartedAt:0
                  groupMetaMessage:groupMetaMessage];
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(nullable TSThread *)thread
                      messageBody:(nullable NSString *)body
                    attachmentIds:(NSMutableArray<NSString *> *)attachmentIds
                 expiresInSeconds:(uint32_t)expiresInSeconds
                  expireStartedAt:(uint64_t)expireStartedAt
                 groupMetaMessage:(TSGroupMetaMessage)groupMetaMessage
{
    self = [super initWithTimestamp:timestamp
                           inThread:thread
                        messageBody:body
                      attachmentIds:attachmentIds
                   expiresInSeconds:expiresInSeconds
                    expireStartedAt:expireStartedAt];
    if (!self) {
        return self;
    }

    _messageState = TSOutgoingMessageStateAttemptingOut;
    _sentRecipients = [NSArray new];
    _hasSyncedTranscript = NO;
    _groupMetaMessage = groupMetaMessage;

    _attachmentFilenameMap = [NSMutableDictionary new];

    return self;
}

- (BOOL)shouldBeSaved
{
    if (!(self.groupMetaMessage == TSGroupMessageDeliver || self.groupMetaMessage == TSGroupMessageNone)) {
        DDLogDebug(@"%@ Skipping save for group meta message.", self.logTag);
        return NO;
    }

    return YES;
}

- (void)saveWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    if (!self.shouldBeSaved) {
        // There's no need to save this message, since it's not displayed to the user.
        //
        // Should we find a need to save this in the future, we need to exclude any non-serializable properties.
        return;
    }

    [super saveWithTransaction:transaction];
}

- (nullable NSString *)recipientIdentifier
{
    return self.thread.contactIdentifier;
}

- (BOOL)shouldStartExpireTimer:(YapDatabaseReadTransaction *)transaction
{
    switch (self.messageState) {
        case TSOutgoingMessageStateSentToService:
            return self.isExpiringMessage;
        case TSOutgoingMessageStateAttemptingOut:
        case TSOutgoingMessageStateUnsent:
            return NO;
        case TSOutgoingMessageStateSent_OBSOLETE:
        case TSOutgoingMessageStateDelivered_OBSOLETE:
            OWSFail(@"%@ Obsolete message state.", self.logTag);
            return self.isExpiringMessage;
    }
}

- (BOOL)isSilent
{
    return NO;
}

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_OutgoingMessage;
}

#pragma mark - Update With... Methods

- (void)updateWithSendingError:(NSError *)error
{
    OWSAssert(error);

    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self applyChangeToSelfAndLatestCopy:transaction
                                 changeBlock:^(TSOutgoingMessage *message) {
                                     [message setMessageState:TSOutgoingMessageStateUnsent];
                                     [message setMostRecentFailureText:error.localizedDescription];
                                 }];
    }];
}

- (void)updateWithMessageState:(TSOutgoingMessageState)messageState
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self updateWithMessageState:messageState transaction:transaction];
    }];
}

- (void)updateWithMessageState:(TSOutgoingMessageState)messageState
                   transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setMessageState:messageState];
                             }];
}

- (void)updateWithHasSyncedTranscript:(BOOL)hasSyncedTranscript
                          transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setHasSyncedTranscript:hasSyncedTranscript];
                             }];
}

- (void)updateWithCustomMessage:(NSString *)customMessage transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(customMessage);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setCustomMessage:customMessage];
                             }];
}

- (void)updateWithCustomMessage:(NSString *)customMessage
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self updateWithCustomMessage:customMessage transaction:transaction];
    }];
}

- (void)updateWithDeliveredToRecipientId:(NSString *)recipientId
                       deliveryTimestamp:(NSNumber *_Nullable)deliveryTimestamp
                             transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {

                                 if (deliveryTimestamp) {
                                     NSMutableDictionary<NSString *, NSNumber *> *recipientDeliveryMap
                                         = (message.recipientDeliveryMap ? [message.recipientDeliveryMap mutableCopy]
                                                                         : [NSMutableDictionary new]);
                                     recipientDeliveryMap[recipientId] = deliveryTimestamp;
                                     message.recipientDeliveryMap = [recipientDeliveryMap copy];
                                 }

                                 [message setWasDelivered:YES];
                             }];
}

- (void)updateWithWasSentFromLinkedDeviceWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setMessageState:TSOutgoingMessageStateSentToService];
                                 [message setWasDelivered:YES];
                                 [message setIsFromLinkedDevice:YES];
                             }];
}

- (void)updateWithSingleGroupRecipient:(NSString *)singleGroupRecipient
                           transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);
    OWSAssert(singleGroupRecipient.length > 0);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message setSingleGroupRecipient:singleGroupRecipient];
                             }];
}

#pragma mark - Sent Recipients

- (NSArray<NSString *> *)sentRecipients
{
    @synchronized(self)
    {
        return _sentRecipients;
    }
}

- (void)setSentRecipients:(NSArray<NSString *> *)sentRecipients
{
    @synchronized(self)
    {
        _sentRecipients = [sentRecipients copy];
    }
}

- (void)addSentRecipient:(NSString *)contactId
{
    @synchronized(self)
    {
        OWSAssert(_sentRecipients);
        OWSAssert(contactId.length > 0);

        NSMutableArray *sentRecipients = [_sentRecipients mutableCopy];
        [sentRecipients addObject:contactId];
        _sentRecipients = [sentRecipients copy];
    }
}

- (BOOL)wasSentToRecipient:(NSString *)contactId
{
    OWSAssert(self.sentRecipients);
    OWSAssert(contactId.length > 0);

    return [self.sentRecipients containsObject:contactId];
}

- (NSUInteger)sentRecipientsCount
{
    OWSAssert(self.sentRecipients);

    return self.sentRecipients.count;
}

- (void)updateWithSentRecipient:(NSString *)contactId transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(transaction);
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 [message addSentRecipient:contactId];
                             }];
}

- (void)updateWithReadRecipientId:(NSString *)recipientId
                    readTimestamp:(uint64_t)readTimestamp
                      transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(recipientId.length > 0);
    OWSAssert(transaction);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSOutgoingMessage *message) {
                                 NSMutableDictionary<NSString *, NSNumber *> *recipientReadMap
                                     = (message.recipientReadMap ? [message.recipientReadMap mutableCopy]
                                                                 : [NSMutableDictionary new]);
                                 recipientReadMap[recipientId] = @(readTimestamp);
                                 message.recipientReadMap = [recipientReadMap copy];
                             }];
}

- (nullable NSNumber *)firstRecipientReadTimestamp
{
    NSNumber *result = nil;
    for (NSNumber *timestamp in self.recipientReadMap.allValues) {
        if (!result || (result.unsignedLongLongValue > timestamp.unsignedLongLongValue)) {
            result = timestamp;
        }
    }
    return result;
}

#pragma mark -

- (OWSSignalServiceProtosDataMessageBuilder *)dataMessageBuilder
{
    TSThread *thread = self.thread;
    OWSSignalServiceProtosDataMessageBuilder *builder = [OWSSignalServiceProtosDataMessageBuilder new];
    [builder setTimestamp:self.timestamp];
    [builder setBody:self.body];
    BOOL attachmentWasGroupAvatar = NO;
    if ([thread isKindOfClass:[TSGroupThread class]]) {
        TSGroupThread *gThread = (TSGroupThread *)thread;
        OWSSignalServiceProtosGroupContextBuilder *groupBuilder = [OWSSignalServiceProtosGroupContextBuilder new];

        switch (self.groupMetaMessage) {
            case TSGroupMessageQuit:
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeQuit];
                break;
            case TSGroupMessageUpdate:
            case TSGroupMessageNew: {
                if (gThread.groupModel.groupImage != nil && self.attachmentIds.count == 1) {
                    attachmentWasGroupAvatar = YES;
                    [groupBuilder
                        setAvatar:[self buildAttachmentProtoForAttachmentId:self.attachmentIds[0] filename:nil]];
                }

                [groupBuilder setMembersArray:gThread.groupModel.groupMemberIds];
                [groupBuilder setName:gThread.groupModel.groupName];
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeUpdate];
                break;
            }
            default:
                [groupBuilder setType:OWSSignalServiceProtosGroupContextTypeDeliver];
                break;
        }
        [groupBuilder setId:gThread.groupModel.groupId];
        [builder setGroup:groupBuilder.build];
    }
    if (!attachmentWasGroupAvatar) {
        NSMutableArray *attachments = [NSMutableArray new];
        for (NSString *attachmentId in self.attachmentIds) {
            NSString *sourceFilename = self.attachmentFilenameMap[attachmentId];
            [attachments addObject:[self buildAttachmentProtoForAttachmentId:attachmentId filename:sourceFilename]];
        }
        [builder setAttachmentsArray:attachments];
    }
    [builder setExpireTimer:self.expiresInSeconds];
    return builder;
}

// recipientId is nil when building "sent" sync messages for messages
// sent to groups.
- (OWSSignalServiceProtosDataMessage *)buildDataMessage:(NSString *_Nullable)recipientId
{
    OWSAssert(self.thread);

    OWSSignalServiceProtosDataMessageBuilder *builder = [self dataMessageBuilder];
    [builder setTimestamp:self.timestamp];
    [builder addLocalProfileKeyIfNecessary:self.thread recipientId:recipientId];
    return [builder build];
}

- (NSData *)buildPlainTextData:(SignalRecipient *)recipient
{
    OWSSignalServiceProtosContentBuilder *contentBuilder = [OWSSignalServiceProtosContentBuilder new];
    contentBuilder.dataMessage = [self buildDataMessage:recipient.recipientId];
    return [[contentBuilder build] data];
}

- (BOOL)shouldSyncTranscript
{
    return !self.hasSyncedTranscript;
}

- (OWSSignalServiceProtosAttachmentPointer *)buildAttachmentProtoForAttachmentId:(NSString *)attachmentId
                                                                        filename:(nullable NSString *)filename
{
    OWSAssert(attachmentId.length > 0);

    TSAttachment *attachment = [TSAttachmentStream fetchObjectWithUniqueID:attachmentId];
    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        DDLogError(@"Unexpected type for attachment builder: %@", attachment);
        return nil;
    }
    TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;

    OWSSignalServiceProtosAttachmentPointerBuilder *builder = [OWSSignalServiceProtosAttachmentPointerBuilder new];
    [builder setId:attachmentStream.serverId];
    OWSAssert(attachmentStream.contentType.length > 0);
    [builder setContentType:attachmentStream.contentType];
    DDLogVerbose(@"%@ Sending attachment with filename: '%@'", self.logTag, filename);
    [builder setFileName:filename];
    [builder setSize:attachmentStream.byteCount];
    [builder setKey:attachmentStream.encryptionKey];
    [builder setDigest:attachmentStream.digest];
    [builder setFlags:(self.isVoiceMessage ? OWSSignalServiceProtosAttachmentPointerFlagsVoiceMessage : 0)];

    if ([attachmentStream shouldHaveImageSize]) {
        CGSize imageSize = [attachmentStream imageSize];
        if (imageSize.width < NSIntegerMax && imageSize.height < NSIntegerMax) {
            NSInteger imageWidth = (NSInteger)round(imageSize.width);
            NSInteger imageHeight = (NSInteger)round(imageSize.height);
            if (imageWidth > 0 && imageHeight > 0) {
                [builder setWidth:(UInt32)imageWidth];
                [builder setHeight:(UInt32)imageHeight];
            }
        }
    }

    return [builder build];
}

@end

NS_ASSUME_NONNULL_END
