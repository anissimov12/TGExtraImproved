#import "Headers.h"
#import <objc/runtime.h>

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

// ANTI-DELETE
%hook TelegramAccountStateManager

- (void)addUpdates:(id)updates {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) {
        %orig;
        return;
    }

    NSArray *updatesList = nil;
    @try { updatesList = [updates valueForKey:@"updates"]; } @catch (...) {}
    
    if (![updatesList isKindOfClass:[NSArray class]] || updatesList.count == 0) {
        %orig;
        return;
    }
    
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:updatesList.count];
    BOOL didFilter = NO;
    
    for (id update in updatesList) {
        NSString *cls = NSStringFromClass([update class]);
        if ([cls containsString:@"deleteMessages"] ||
            [cls containsString:@"DeleteMessages"] ||
            [cls containsString:@"deleteChannelMessages"] ||
            [cls containsString:@"DeleteChannelMessages"]) {
            customLog(@"[AntiDelete] Blocked update class: %@", cls);
            didFilter = YES;
            continue;
        }
        [filtered addObject:update];
    }
    
    if (!didFilter) {
        %orig;
        return;
    }

    @try {
        NSObject *mutableUpdates = [updates mutableCopy];
        [mutableUpdates setValue:filtered forKey:@"updates"];
        %orig(mutableUpdates);
    } @catch (NSException *e) {
        customLog2(@"[AntiDelete] KVC failed: %@, falling through", e);
        %orig;
    }
}

%end

%hook TelegramAccountStateManager2

- (void)addUpdateShort:(id)update {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) {
        NSString *cls = NSStringFromClass([update class]);
        if ([cls containsString:@"deleteMessages"] || [cls containsString:@"DeleteMessages"]) {
            customLog(@"[AntiDelete] Blocked short update: %@", cls);
            return;
        }
    }
    %orig;
}

%end

__attribute__((constructor))
static void initAntiDeleteHooks() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        const char *stateManagerNames[] = {
            "TelegramCore.AccountStateManager",
            "AccountStateManager",
        };
        
        Class stateManagerClass = Nil;
        for (int i = 0; i < 2; i++) {
            stateManagerClass = objc_getClass(stateManagerNames[i]);
            if (stateManagerClass) {
                customLog(@"[AntiDelete] Found StateManager: %s", stateManagerNames[i]);
                break;
            }
        }

        if (!stateManagerClass) {
            int numClasses = objc_getClassList(NULL, 0);
            Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
            numClasses = objc_getClassList(classes, numClasses);
            
            for (int i = 0; i < numClasses; i++) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name containsString:@"AccountStateManager"] ||
                    [name containsString:@"StateManager"]) {
                    customLog2(@"[AntiDelete] Candidate: %@", name);
                    
                    if ([classes[i] instancesRespondToSelector:@selector(addUpdates:)] ||
                        class_getInstanceMethod(classes[i], NSSelectorFromString(@"addUpdates:"))) {
                        stateManagerClass = classes[i];
                        customLog(@"[AntiDelete] Using: %@", name);
                        break;
                    }
                }
            }
            free(classes);
        }
        
        if (stateManagerClass) {
            %init(TelegramAccountStateManager = stateManagerClass);
        } else {
            customLog2(@"[AntiDelete] StateManager not found");
        }
    });
}
