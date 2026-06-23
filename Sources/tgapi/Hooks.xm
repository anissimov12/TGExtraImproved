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

static IMP orig_addUpdates = NULL;
static IMP orig_addUpdateShort = NULL;

static void hooked_addUpdates(id self, SEL _cmd, id updates) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) {
        ((void(*)(id,SEL,id))orig_addUpdates)(self, _cmd, updates);
        return;
    }

    customLog2(@"[AntiDelete] addUpdates: called, updates class = %@", NSStringFromClass([updates class]));

    NSArray *updatesList = nil;
    @try { updatesList = [updates valueForKey:@"updates"]; } @catch (...) {}
    if (![updatesList isKindOfClass:[NSArray class]]) {
        @try { updatesList = [updates valueForKey:@"_updates"]; } @catch (...) {}
    }

    if (![updatesList isKindOfClass:[NSArray class]] || updatesList.count == 0) {
        customLog2(@"[AntiDelete] no updates array found, passing through");
        ((void(*)(id,SEL,id))orig_addUpdates)(self, _cmd, updates);
        return;
    }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:updatesList.count];
    BOOL didFilter = NO;

    for (id update in updatesList) {
        NSString *cls = NSStringFromClass([update class]);
        customLog2(@"[AntiDelete] update class: %@", cls);
        if ([cls rangeOfString:@"elete" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            [cls rangeOfString:@"essage" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            customLog(@"[AntiDelete] BLOCKED update: %@", cls);
            didFilter = YES;
            continue;
        }
        [filtered addObject:update];
    }

    if (!didFilter) {
        ((void(*)(id,SEL,id))orig_addUpdates)(self, _cmd, updates);
        return;
    }

    BOOL kvcOK = NO;
    @try {
        [updates setValue:filtered forKey:@"updates"];
        kvcOK = YES;
    } @catch (...) {}

    if (!kvcOK) {
        @try {
            [updates setValue:filtered forKey:@"_updates"];
            kvcOK = YES;
        } @catch (...) {}
    }

    if (kvcOK) {
        customLog(@"[AntiDelete] filtered %lu delete update(s), calling orig", (unsigned long)(updatesList.count - filtered.count));
        ((void(*)(id,SEL,id))orig_addUpdates)(self, _cmd, updates);
    } else {
        customLog2(@"[AntiDelete] KVC failed, dropping entire addUpdates: call");
    }
}

static void hooked_addUpdateShort(id self, SEL _cmd, id update) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) {
        NSString *cls = NSStringFromClass([update class]);
        customLog2(@"[AntiDelete] addUpdateShort: class = %@", cls);
        if ([cls rangeOfString:@"elete" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            [cls rangeOfString:@"essage" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            customLog(@"[AntiDelete] BLOCKED short update: %@", cls);
            return;
        }
    }
    ((void(*)(id,SEL,id))orig_addUpdateShort)(self, _cmd, update);
}

static BOOL swizzleMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *origIMP = method_setImplementation(m, newIMP);
    customLog(@"[AntiDelete] swizzled %@ -[%s]", NSStringFromClass(cls), sel_getName(sel));
    return YES;
}

__attribute__((constructor))
static void initAntiDeleteHooks() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        SEL addUpdatesSel   = NSSelectorFromString(@"addUpdates:");
        SEL addUpdateShortSel = NSSelectorFromString(@"addUpdateShort:");

        const char *knownNames[] = {
            "TelegramCore.AccountStateManager",
            "_TtC12TelegramCore19AccountStateManager",
            "AccountStateManager",
        };

        BOOL foundAddUpdates = NO;
        BOOL foundAddUpdateShort = NO;

        for (int i = 0; i < 3; i++) {
            Class cls = objc_getClass(knownNames[i]);
            if (!cls) continue;
            customLog(@"[AntiDelete] Trying known class: %s", knownNames[i]);

            if (!foundAddUpdates && class_getInstanceMethod(cls, addUpdatesSel)) {
                foundAddUpdates = swizzleMethod(cls, addUpdatesSel, (IMP)hooked_addUpdates, &orig_addUpdates);
            }
            if (!foundAddUpdateShort && class_getInstanceMethod(cls, addUpdateShortSel)) {
                foundAddUpdateShort = swizzleMethod(cls, addUpdateShortSel, (IMP)hooked_addUpdateShort, &orig_addUpdateShort);
            }
        }

        if (!foundAddUpdates || !foundAddUpdateShort) {
            customLog2(@"[AntiDelete] Known classes not found, scanning all classes...");

            unsigned int numClasses = 0;
            Class *classes = objc_copyClassList(&numClasses);

            for (unsigned int i = 0; i < numClasses; i++) {
                NSString *name = NSStringFromClass(classes[i]);

                if ([name containsString:@"StateManager"] || [name containsString:@"Update"]) {
                    if (class_getInstanceMethod(classes[i], addUpdatesSel) ||
                        class_getInstanceMethod(classes[i], addUpdateShortSel)) {
                        customLog2(@"[AntiDelete] Candidate: %@", name);
                    }
                }

                if (!foundAddUpdates && class_getInstanceMethod(classes[i], addUpdatesSel)) {
                    if ([name containsString:@"State"] || [name containsString:@"Manager"] ||
                        [name containsString:@"Account"] || [name containsString:@"Update"]) {
                        foundAddUpdates = swizzleMethod(classes[i], addUpdatesSel, (IMP)hooked_addUpdates, &orig_addUpdates);
                    }
                }

                if (!foundAddUpdateShort && class_getInstanceMethod(classes[i], addUpdateShortSel)) {
                    if ([name containsString:@"State"] || [name containsString:@"Manager"] ||
                        [name containsString:@"Account"] || [name containsString:@"Update"]) {
                        foundAddUpdateShort = swizzleMethod(classes[i], addUpdateShortSel, (IMP)hooked_addUpdateShort, &orig_addUpdateShort);
                    }
                }

                if (foundAddUpdates && foundAddUpdateShort) break;
            }
            free(classes);
        }

        if (!foundAddUpdates) {
            customLog2(@"[AntiDelete] addUpdates: NOT found in any class");
        }
        if (!foundAddUpdateShort) {
            customLog2(@"[AntiDelete] addUpdateShort: NOT found (may be normal)");
        }
    });
}
