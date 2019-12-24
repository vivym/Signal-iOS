//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSReadReceiptManager.h"
#import "AppReadiness.h"
#import "OWSLinkedDeviceReadReceipt.h"
#import "OWSMessageSender.h"
#import "OWSOutgoingReceiptManager.h"
#import "OWSReadReceiptsForLinkedDevicesMessage.h"
#import "OWSReceiptsForSenderMessage.h"
#import "SSKEnvironment.h"
#import "TSAccountManager.h"
#import "TSContactThread.h"
#import "TSIncomingMessage.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/Threading.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kIncomingMessageMarkedAsReadNotification = @"kIncomingMessageMarkedAsReadNotification";
NSUInteger const TSRecipientReadReceiptSchemaVersion = 1;

@interface TSRecipientReadReceipt ()

@property (nonatomic, readonly) NSUInteger recipientReadReceiptSchemaVersion;

@end

@implementation TSRecipientReadReceipt

+ (NSString *)collection
{
    return @"TSRecipientReadReceipt2";
}

- (instancetype)initWithSentTimestamp:(uint64_t)sentTimestamp
{
    OWSAssertDebug(sentTimestamp > 0);

    self = [super initWithUniqueId:[TSRecipientReadReceipt uniqueIdForSentTimestamp:sentTimestamp]];

    if (self) {
        _sentTimestamp = sentTimestamp;
        _recipientMap = [NSDictionary new];
        _recipientReadReceiptSchemaVersion = TSRecipientReadReceiptSchemaVersion;
    }

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    if (_recipientReadReceiptSchemaVersion < 1) {
        NSDictionary<NSString *, NSNumber *> *legacyRecipientMap = [coder decodeObjectForKey:@"recipientMap"];
        NSMutableDictionary<SignalServiceAddress *, NSNumber *> *recipientMap = [NSMutableDictionary new];
        [legacyRecipientMap
            enumerateKeysAndObjectsUsingBlock:^(NSString *phoneNumber, NSNumber *timestamp, BOOL *stop) {
                recipientMap[[[SignalServiceAddress alloc] initWithPhoneNumber:phoneNumber]] = timestamp;
            }];
        _recipientMap = [recipientMap copy];
    }

    _recipientReadReceiptSchemaVersion = TSRecipientReadReceiptSchemaVersion;

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                    recipientMap:(NSDictionary<SignalServiceAddress *,NSNumber *> *)recipientMap
                   sentTimestamp:(uint64_t)sentTimestamp
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _recipientMap = recipientMap;
    _sentTimestamp = sentTimestamp;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

+ (NSString *)uniqueIdForSentTimestamp:(uint64_t)timestamp
{
    return [NSString stringWithFormat:@"%llu", timestamp];
}

- (void)addRecipient:(SignalServiceAddress *)address timestamp:(uint64_t)timestamp
{
    OWSAssertDebug(address.isValid);
    OWSAssertDebug(timestamp > 0);

    NSMutableDictionary<SignalServiceAddress *, NSNumber *> *recipientMapCopy = [self.recipientMap mutableCopy];
    recipientMapCopy[address] = @(timestamp);
    _recipientMap = [recipientMapCopy copy];
}

+ (void)addRecipient:(SignalServiceAddress *)address
       sentTimestamp:(uint64_t)sentTimestamp
       readTimestamp:(uint64_t)readTimestamp
         transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    if (!recipientReadReceipt) {
        recipientReadReceipt = [[TSRecipientReadReceipt alloc] initWithSentTimestamp:sentTimestamp];
        [recipientReadReceipt addRecipient:address timestamp:readTimestamp];
        [recipientReadReceipt anyInsertWithTransaction:transaction];
    } else {
        [recipientReadReceipt anyUpdateWithTransaction:transaction
                                                 block:^(TSRecipientReadReceipt *recipientReadReceipt) {
                                                     [recipientReadReceipt addRecipient:address
                                                                              timestamp:readTimestamp];
                                                 }];
    }
}

+ (nullable NSDictionary<SignalServiceAddress *, NSNumber *> *)recipientMapForSentTimestamp:(uint64_t)sentTimestamp
                                                                                transaction:(SDSAnyWriteTransaction *)
                                                                                                transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    return recipientReadReceipt.recipientMap;
}

+ (void)removeRecipientIdsForTimestamp:(uint64_t)sentTimestamp transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    NSString *uniqueId = [self uniqueIdForSentTimestamp:sentTimestamp];
    TSRecipientReadReceipt *_Nullable recipientReadReceipt =
        [TSRecipientReadReceipt anyFetchWithUniqueId:uniqueId transaction:transaction];
    if (recipientReadReceipt != nil) {
        [recipientReadReceipt anyRemoveWithTransaction:transaction];
    }
}

@end

#pragma mark -

NSString *const OWSReadReceiptManagerCollection = @"OWSReadReceiptManagerCollection";
NSString *const OWSReadReceiptManagerAreReadReceiptsEnabled = @"areReadReceiptsEnabled";

@interface OWSReadReceiptManager ()

// A map of "thread unique id"-to-"read receipt" for read receipts that
// we will send to our linked devices.
//
// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, OWSLinkedDeviceReadReceipt *> *toLinkedDevicesReadReceiptMap;

// Should only be accessed while synchronized on the OWSReadReceiptManager.
@property (nonatomic) BOOL isProcessing;

@property (atomic) NSNumber *areReadReceiptsEnabledCached;

@end

#pragma mark -

@implementation OWSReadReceiptManager

+ (SDSKeyValueStore *)keyValueStore
{
    static SDSKeyValueStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SDSKeyValueStore alloc] initWithCollection:OWSReadReceiptManagerCollection];
    });
    return instance;
}

+ (instancetype)sharedManager
{
    OWSAssert(SSKEnvironment.shared.readReceiptManager);

    return SSKEnvironment.shared.readReceiptManager;
}

- (instancetype)init
{
    self = [super init];

    if (!self) {
        return self;
    }

    _toLinkedDevicesReadReceiptMap = [NSMutableDictionary new];

    OWSSingletonAssert();

    // Start processing.
    [AppReadiness runNowOrWhenAppDidBecomeReady:^{
        [self scheduleProcessing];
    }];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Dependencies

- (MessageSenderJobQueue *)messageSenderJobQueue
{
    return SSKEnvironment.shared.messageSenderJobQueue;
}

- (OWSOutgoingReceiptManager *)outgoingReceiptManager
{
    OWSAssertDebug(SSKEnvironment.shared.outgoingReceiptManager);

    return SSKEnvironment.shared.outgoingReceiptManager;
}

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

#pragma mark -

// Schedules a processing pass, unless one is already scheduled.
- (void)scheduleProcessing
{
    OWSAssertDebug(AppReadiness.isAppReady);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(self)
        {
            if (self.isProcessing) {
                return;
            }

            self.isProcessing = YES;

            [self process];
        }
    });
}

- (void)process
{
    if (SSKFeatureFlags.suppressBackgroundActivity) {
        // Don't process queues.
        return;
    }

    @synchronized(self)
    {
        OWSLogVerbose(@"Processing read receipts.");

        NSArray<OWSLinkedDeviceReadReceipt *> *readReceiptsForLinkedDevices =
            [self.toLinkedDevicesReadReceiptMap allValues];
        [self.toLinkedDevicesReadReceiptMap removeAllObjects];
        if (readReceiptsForLinkedDevices.count > 0) {
            [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
                TSThread *_Nullable thread = [TSAccountManager getOrCreateLocalThreadWithTransaction:transaction];
                if (thread == nil) {
                    OWSFailDebug(@"Missing thread.");
                    return;
                }

                OWSReadReceiptsForLinkedDevicesMessage *message =
                    [[OWSReadReceiptsForLinkedDevicesMessage alloc] initWithThread:thread
                                                                      readReceipts:readReceiptsForLinkedDevices];

                [self.messageSenderJobQueue addMessage:message.asPreparer transaction:transaction];
            }];
        }

        BOOL didWork = readReceiptsForLinkedDevices.count > 0;

        if (didWork) {
            // Wait N seconds before processing read receipts again.
            // This allows time for a batch to accumulate.
            //
            // We want a value high enough to allow us to effectively de-duplicate,
            // read receipts without being so high that we risk not sending read
            // receipts due to app exit.
            const CGFloat kProcessingFrequencySeconds = 3.f;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProcessingFrequencySeconds * NSEC_PER_SEC)),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{
                    [self process];
                });
        } else {
            self.isProcessing = NO;
        }
    }
}

#pragma mark - Mark as Read Locally

- (dispatch_queue_t)markAsReadSerialQueue
{
    static dispatch_queue_t serialQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        serialQueue = dispatch_queue_create("org.whispersystems.readReceiptManager", DISPATCH_QUEUE_SERIAL);
    });
    return serialQueue;
}

- (void)markAsReadLocallyBeforeSortId:(uint64_t)sortId thread:(TSThread *)thread completion:(void (^)(void))completion
{
    OWSAssertDebug(thread);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t readTimestamp = [NSDate ows_millisecondTimeStamp];
        __block NSArray<id<OWSReadTracking>> *unreadMessages;
        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
            unreadMessages = [self unreadMessagesBeforeSortId:sortId
                                                       thread:thread
                                                readTimestamp:readTimestamp
                                                  transaction:transaction];
        }];
        if (unreadMessages.count < 1) {
            // Avoid unnecessary writes.
            dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
            [self markMessagesAsRead:unreadMessages readTimestamp:readTimestamp wasLocal:YES transaction:transaction];
        }];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)messageWasReadLocally:(TSIncomingMessage *)message
{
    // It's possible to mark hundreds of messages (or more) as read at a time
    // in conversation view.  We use a serial queue to avoid overwhelming GCD
    // in that case.
    dispatch_async(self.markAsReadSerialQueue, ^{
        NSString *threadUniqueId = message.uniqueThreadId;
        OWSAssertDebug(threadUniqueId.length > 0);

        SignalServiceAddress *messageAuthorAddress = message.authorAddress;
        OWSAssertDebug(messageAuthorAddress.isValid);

        OWSLinkedDeviceReadReceipt *newReadReceipt =
            [[OWSLinkedDeviceReadReceipt alloc] initWithSenderAddress:messageAuthorAddress
                                                   messageIdTimestamp:message.timestamp
                                                        readTimestamp:[NSDate ows_millisecondTimeStamp]];

        @synchronized(self) {
            OWSLinkedDeviceReadReceipt *_Nullable oldReadReceipt = self.toLinkedDevicesReadReceiptMap[threadUniqueId];
            if (oldReadReceipt && oldReadReceipt.messageIdTimestamp > newReadReceipt.messageIdTimestamp) {
                // If there's an existing "linked device" read receipt for the same thread with
                // a newer timestamp, discard this "linked device" read receipt.
                OWSLogVerbose(@"Ignoring redundant read receipt for linked devices.");
            } else {
                OWSLogVerbose(@"Enqueuing read receipt for linked devices.");
                self.toLinkedDevicesReadReceiptMap[threadUniqueId] = newReadReceipt;
            }
        }

        if (message.authorAddress.isLocalAddress) {
            OWSLogVerbose(@"Ignoring read receipt for self-sender.");
            return;
        }

        if ([self areReadReceiptsEnabled]) {
            OWSLogVerbose(@"Enqueuing read receipt for sender.");
            [self.outgoingReceiptManager enqueueReadReceiptForAddress:messageAuthorAddress timestamp:message.timestamp];
        }

        [self scheduleProcessing];
    });
}

#pragma mark - Read Receipts From Recipient

- (void)processReadReceiptsFromRecipient:(SignalServiceAddress *)address
                          sentTimestamps:(NSArray<NSNumber *> *)sentTimestamps
                           readTimestamp:(uint64_t)readTimestamp
{
    OWSAssertDebug(address.isValid);
    OWSAssertDebug(sentTimestamps);

    if (![self areReadReceiptsEnabled]) {
        OWSLogInfo(@"Ignoring incoming receipt message as read receipts are disabled.");
        return;
    }

    [self.databaseStorage asyncWriteWithBlock:^(SDSAnyWriteTransaction *transaction) {
        for (NSNumber *nsSentTimestamp in sentTimestamps) {
            UInt64 sentTimestamp = [nsSentTimestamp unsignedLongLongValue];

            NSError *error;
            NSArray<TSOutgoingMessage *> *messages = (NSArray<TSOutgoingMessage *> *)[InteractionFinder
                interactionsWithTimestamp:sentTimestamp
                                   filter:^(TSInteraction *interaction) {
                                       return [interaction isKindOfClass:[TSOutgoingMessage class]];
                                   }
                              transaction:transaction
                                    error:&error];
            if (error != nil) {
                OWSFailDebug(@"Error loading interactions: %@", error);
            }

            if (messages.count > 1) {
                OWSLogError(@"More than one matching message with timestamp: %llu.", sentTimestamp);
            }
            if (messages.count > 0) {
                // TODO: We might also need to "mark as read by recipient" any older messages
                // from us in that thread.  Or maybe this state should hang on the thread?
                for (TSOutgoingMessage *message in messages) {
                    [message updateWithReadRecipient:address readTimestamp:readTimestamp transaction:transaction];
                }
            } else {
                // Persist the read receipts so that we can apply them to outgoing messages
                // that we learn about later through sync messages.
                [TSRecipientReadReceipt addRecipient:address
                                       sentTimestamp:sentTimestamp
                                       readTimestamp:readTimestamp
                                         transaction:transaction];
            }
        }
    }];
}

- (void)applyEarlyReadReceiptsForOutgoingMessageFromLinkedDevice:(TSOutgoingMessage *)message
                                                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    uint64_t sentTimestamp = message.timestamp;
    NSDictionary<SignalServiceAddress *, NSNumber *> *recipientMap =
        [TSRecipientReadReceipt recipientMapForSentTimestamp:sentTimestamp transaction:transaction];
    if (!recipientMap) {
        return;
    }
    OWSAssertDebug(recipientMap.count > 0);
    for (SignalServiceAddress *address in recipientMap) {
        NSNumber *nsReadTimestamp = recipientMap[address];
        OWSAssertDebug(nsReadTimestamp);
        uint64_t readTimestamp = [nsReadTimestamp unsignedLongLongValue];

        [message updateWithReadRecipient:address readTimestamp:readTimestamp transaction:transaction];
    }
    [TSRecipientReadReceipt removeRecipientIdsForTimestamp:message.timestamp transaction:transaction];
}

#pragma mark - Linked Device Read Receipts

- (void)applyEarlyReadReceiptsForIncomingMessage:(TSIncomingMessage *)message
                                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    SignalServiceAddress *senderAddress = message.authorAddress;
    uint64_t timestamp = message.timestamp;
    if (!senderAddress.isValid || timestamp < 1) {
        OWSFailDebug(@"Invalid incoming message: %@ %llu", senderAddress, timestamp);
        return;
    }

    OWSLinkedDeviceReadReceipt *_Nullable readReceipt =
        [OWSLinkedDeviceReadReceipt findLinkedDeviceReadReceiptWithAddress:senderAddress
                                                        messageIdTimestamp:timestamp
                                                               transaction:transaction];
    if (!readReceipt) {
        return;
    }

    [message markAsReadAtTimestamp:readReceipt.readTimestamp sendReadReceipt:NO transaction:transaction];
    [readReceipt anyRemoveWithTransaction:transaction];
}

- (void)processReadReceiptsFromLinkedDevice:(NSArray<SSKProtoSyncMessageRead *> *)readReceiptProtos
                              readTimestamp:(uint64_t)readTimestamp
                                transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(readReceiptProtos);
    OWSAssertDebug(transaction);

    for (SSKProtoSyncMessageRead *readReceiptProto in readReceiptProtos) {
        SignalServiceAddress *_Nullable senderAddress = readReceiptProto.senderAddress;
        uint64_t messageIdTimestamp = readReceiptProto.timestamp;

        OWSAssertDebug(senderAddress.isValid);

        if (messageIdTimestamp == 0) {
            OWSFailDebug(@"messageIdTimestamp was unexpectedly 0");
            continue;
        }
        if (![SDS fitsInInt64:messageIdTimestamp]) {
            OWSFailDebug(@"Invalid messageIdTimestamp.");
            continue;
        }

        NSError *error;
        NSArray<TSIncomingMessage *> *messages = (NSArray<TSIncomingMessage *> *)[InteractionFinder
            interactionsWithTimestamp:messageIdTimestamp
                               filter:^(TSInteraction *interaction) {
                                   return [interaction isKindOfClass:[TSIncomingMessage class]];
                               }
                          transaction:transaction
                                error:&error];
        if (error != nil) {
            OWSFailDebug(@"Error loading interactions: %@", error);
        }

        if (messages.count > 0) {
            for (TSIncomingMessage *message in messages) {
                NSTimeInterval secondsSinceRead = [NSDate new].timeIntervalSince1970 - readTimestamp / 1000;
                OWSAssertDebug([message isKindOfClass:[TSIncomingMessage class]]);
                OWSLogDebug(@"read on linked device %f seconds ago", secondsSinceRead);
                [self markAsReadOnLinkedDevice:message readTimestamp:readTimestamp transaction:transaction];
            }
        } else {
            // Received read receipt for unknown incoming message.
            // Persist in case we receive the incoming message later.
            OWSLinkedDeviceReadReceipt *readReceipt =
                [[OWSLinkedDeviceReadReceipt alloc] initWithSenderAddress:senderAddress
                                                       messageIdTimestamp:messageIdTimestamp
                                                            readTimestamp:readTimestamp];
            [readReceipt anyInsertWithTransaction:transaction];
        }
    }
}

- (void)markAsReadOnLinkedDevice:(TSIncomingMessage *)message
                   readTimestamp:(uint64_t)readTimestamp
                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message);
    OWSAssertDebug(transaction);

    // Always re-mark the message as read to ensure any earlier read time is applied to disappearing messages.
    [message markAsReadAtTimestamp:readTimestamp sendReadReceipt:NO transaction:transaction];

    // Also mark any unread messages appearing earlier in the thread as read as well.
    [self markAsReadBeforeSortId:message.sortId
                          thread:[message threadWithTransaction:transaction]
                   readTimestamp:readTimestamp
                        wasLocal:NO
                     transaction:transaction];
}

#pragma mark - Mark As Read

- (void)markAsReadBeforeSortId:(uint64_t)sortId
                        thread:(TSThread *)thread
                 readTimestamp:(uint64_t)readTimestamp
                      wasLocal:(BOOL)wasLocal
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(sortId > 0);
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);

    NSArray<id<OWSReadTracking>> *unreadMessages =
        [self unreadMessagesBeforeSortId:sortId thread:thread readTimestamp:readTimestamp transaction:transaction];
    if (unreadMessages.count < 1) {
        // Avoid unnecessary writes.
        return;
    }
    [self markMessagesAsRead:unreadMessages readTimestamp:readTimestamp wasLocal:wasLocal transaction:transaction];
}

- (void)markMessagesAsRead:(NSArray<id<OWSReadTracking>> *)unreadMessages
             readTimestamp:(uint64_t)readTimestamp
                  wasLocal:(BOOL)wasLocal
               transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(unreadMessages.count > 0);
    OWSAssertDebug(transaction);

    if (wasLocal) {
        OWSLogError(@"Marking %lu messages as read locally.", (unsigned long)unreadMessages.count);
    } else {
        OWSLogError(@"Marking %lu messages as read by linked device.", (unsigned long)unreadMessages.count);
    }
    for (id<OWSReadTracking> readItem in unreadMessages) {
        [readItem markAsReadAtTimestamp:readTimestamp sendReadReceipt:wasLocal transaction:transaction];
    }
}

- (NSArray<id<OWSReadTracking>> *)unreadMessagesBeforeSortId:(uint64_t)sortId
                                                      thread:(TSThread *)thread
                                               readTimestamp:(uint64_t)readTimestamp
                                                 transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(sortId > 0);
    OWSAssertDebug(thread);
    OWSAssertDebug(transaction);

    // POST GRDB TODO: We could pass readTimestamp and sortId through to the GRDB query.
    NSMutableArray<id<OWSReadTracking>> *newlyReadList = [NSMutableArray new];
    InteractionFinder *interactionFinder = [[InteractionFinder alloc] initWithThreadUniqueId:thread.uniqueId];
    NSError *error;
    [interactionFinder
        enumerateUnseenInteractionsWithTransaction:transaction
                                           error:&error
                                           block:^(TSInteraction *interaction, BOOL *stop) {
                                               if (![interaction conformsToProtocol:@protocol(OWSReadTracking)]) {
                                                   OWSFailDebug(@"Expected to conform to OWSReadTracking: object "
                                                                @"with class: %@ collection: %@ "
                                                                @"key: %@",
                                                       [interaction class],
                                                       TSInteraction.collection,
                                                       interaction.uniqueId);
                                                   return;
                                               }
                                               id<OWSReadTracking> possiblyRead = (id<OWSReadTracking>)interaction;
                                               if (possiblyRead.sortId > sortId) {
                                                   *stop = YES;
                                                   return;
                                               }

                                               OWSAssertDebug(!possiblyRead.read);
                                               OWSAssertDebug(possiblyRead.expireStartedAt == 0);
                                               if (!possiblyRead.read) {
                                                   [newlyReadList addObject:possiblyRead];
                                               }
                                           }];
    if (error != nil) {
        OWSFailDebug(@"Error during enumeration: %@", error);
    }
    return [newlyReadList copy];
}

#pragma mark - Settings

- (void)prepareCachedValues
{
    [self areReadReceiptsEnabled];
}

- (BOOL)areReadReceiptsEnabled
{
    // We don't need to worry about races around this cached value.
    if (!self.areReadReceiptsEnabledCached) {
        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
            self.areReadReceiptsEnabledCached =
                @([OWSReadReceiptManager.keyValueStore getBool:OWSReadReceiptManagerAreReadReceiptsEnabled
                                                  defaultValue:NO
                                                   transaction:transaction]);
        }];
    }

    return [self.areReadReceiptsEnabledCached boolValue];
}

- (void)setAreReadReceiptsEnabledWithSneakyTransactionAndSyncConfiguration:(BOOL)value
{
    OWSLogInfo(@"setAreReadReceiptsEnabled: %d.", value);

    [self.databaseStorage writeWithBlock:^(SDSAnyWriteTransaction *transaction) {
        [self setAreReadReceiptsEnabled:value transaction:transaction];
    }];

    [SSKEnvironment.shared.syncManager sendConfigurationSyncMessage];
}


- (void)setAreReadReceiptsEnabled:(BOOL)value transaction:(SDSAnyWriteTransaction *)transaction
{
    [OWSReadReceiptManager.keyValueStore setBool:value
                                             key:OWSReadReceiptManagerAreReadReceiptsEnabled
                                     transaction:transaction];
    self.areReadReceiptsEnabledCached = @(value);
}

@end

NS_ASSUME_NONNULL_END
