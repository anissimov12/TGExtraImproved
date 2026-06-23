#import "Headers.h"

#define kChannelsReadHistory -871347913

%hook MTRequest
%property (nonatomic, strong) NSData *fakeData;
%property (nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
	
	// Extract Function id 
	int32_t functionID;
	[payload getBytes:&functionID length:4];
	self.functionID = [NSNumber numberWithInt:functionID];
	
	id(^hooked_block)(NSData *) = ^id(NSData *inputData) {
		NSNumber *functionIDNumber = [NSNumber numberWithUnsignedInt:functionID];
		NSData *fuck = [TLParser handleResponse:inputData functionID:functionIDNumber];
		id result;
		if (fuck) {
			result = responseParser(fuck);
		} else {
			result = responseParser(inputData);
		}
		return result;
	};
	
	switch (functionID) {
		case kAccountUpdateOnlineStatus:
			handleOnlineStatus(self, payload);
			break;
		case kMessagesSetTypingAction:
			handleSetTyping(self, payload);
			break;
		case kMessagesReadHistory:
			handleMessageReadReceipt(self, payload);
			break;
		case kStoriesReadStories:
			handleStoriesReadReceipt(self, payload);
			break;
		case kGetSponsoredMessages:
			handleGetSponsoredMessages(self, payload);
			break;
		case kChannelsReadHistory:
			handleChannelsReadReceipt(self, payload);
			break;
		default:
			break;
	}
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) {
		%orig(payload, metadata, shortMetadata, hooked_block);
	} else {
		%orig(payload, metadata, shortMetadata, responseParser);
	}
}

%end

// Manager which handles requests
%hook MTRequestMessageService

- (void)addRequest:(MTRequest *)request {
    if (request.fakeData) {
        @try {
             if (request.completed) {
                 NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];

                 MTRequestResponseInfo *info = [[%c(MTRequestResponseInfo) alloc] initWithNetworkType:1 
					     timestamp:currentTime 
						 duration:0.045
					];
						
						id result = request.responseParser(request.fakeData);
						request.completed(result, info, nil);
             }
         } @catch (NSException *exception) {
             customLog2(@"Exception in MTRequestMessageService hook: %@", exception);
         }
        return;
    }
    %orig;
}

%end

// ============================================================
// ANTI-DELETE: перехват на уровне входящих MTProto данных
// Updates приходят НЕ через responseParser, а через отдельный
// канал — MTProtoInstance/MTProto processUpdates.
// Хукаем метод который применяет апдейты к локальному состоянию.
// ============================================================

static BOOL shouldFilterDeleteUpdate(NSData *data) {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) return NO;
	if (data.length < 4) return NO;
	
	int32_t constructorID = 0;
	[data getBytes:&constructorID length:4];
	
	return (constructorID == kUpdateDeleteMessages || constructorID == kUpdateDeleteChannelMessages);
}

// Хук на MTProto — обрабатывает входящие данные от сервера
%hook MTProto

- (void)transportReceivedData:(NSData *)data {
	if (shouldFilterDeleteUpdate(data)) {
		customLog(@"[AntiDelete] Blocked incoming delete update at transport level");
		return;
	}
	%orig;
}

%end

// Хук на объект который разбирает Updates контейнер
%hook MTIncomingMessage

- (id)initWithData:(NSData *)data {
	if (shouldFilterDeleteUpdate(data)) {
		customLog(@"[AntiDelete] Blocked incoming delete update at message level");
		return nil;
	}
	return %orig;
}

%end

__attribute__((constructor))
static void initAntiDeleteHooks() {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		// Ищем классы MTProto динамически т.к. они в модульном фреймворке
		Class mtProtoClass = objc_getClass("MTProto");
		Class mtIncomingClass = objc_getClass("MTIncomingMessage");
		
		if (mtProtoClass && mtIncomingClass) {
			%init(
				MTProto = mtProtoClass,
				MTIncomingMessage = mtIncomingClass
			);
			customLog(@"[AntiDelete] Hooks initialized successfully");
		} else {
			customLog2(@"[AntiDelete] Failed to find MTProto classes");
		}
	});
}
