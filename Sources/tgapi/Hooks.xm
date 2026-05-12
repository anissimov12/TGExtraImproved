#import "Headers.h"

#define kChannelsReadHistory -871347913
// Nuovi ID per Anti-Delete
#define kMessagesDeleteMessages -443639891   // 0xe58e95ad
#define kChannelsDeleteMessages -2067628722  // 0x84c1fd4e
#define kUpdateDeleteMessages 0xa200a095     // Update in entrata
#define kUpdateDeleteChannelMessages 0xc32d34f9

%hook MTRequest
%property (nonatomic, strong) NSData *fakeData;
%property (nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
	
	// Extract Function id 
	int32_t functionID;
	[payload getBytes:&functionID length:4];
	self.functionID = [NSNumber numberWithInt:functionID];
	
	id(^hooked_block)(NSData *) = ^(NSData *inputData) {
		// --- LOGICA ANTI-DELETE IN ENTRATA ---
		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"enableAntiDelete"]) {
			int32_t responseID;
			[inputData getBytes:&responseID length:4];
			
			// Se il pacchetto in arrivo è un comando di eliminazione, lo ignoriamo
			if (responseID == kUpdateDeleteMessages || responseID == kUpdateDeleteChannelMessages) {
				customLog(@"[TGExtra] Anti-Delete: Bloccato comando di eliminazione dal server.");
				return (NSData *)nil; 
			}
		}

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
		// Gestione richieste di eliminazione in uscita (opzionale)
		case kMessagesDeleteMessages:
		case kChannelsDeleteMessages:
			if ([[NSUserDefaults standardUserDefaults] boolForKey:@"enableAntiDelete"]) {
				customLog(@"[TGExtra] Richiesta eliminazione in uscita intercettata.");
			}
			break;
		default:
			break;
	}
	
	// Applichiamo il hooked_block se una delle funzioni di modifica è attiva
	BOOL shouldHook = [[NSUserDefaults standardUserDefaults] boolForKey:@"disableForwardRestriction"] || 
					  [[NSUserDefaults standardUserDefaults] boolForKey:@"enableAntiDelete"];

	if (shouldHook) {
		%orig(payload, metadata, shortMetadata, hooked_block);
	} else {
		%orig(payload, metadata, shortMetadata, responseParser);
	}
}

%end

// Manager che gestisce le richieste (rimane invariato)
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
