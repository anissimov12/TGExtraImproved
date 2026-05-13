#import "Headers.h"

#define kChannelsReadHistory -871347913

%hook MTRequest
%property (nonatomic, strong) NSData *fakeData;
%property (nonatomic, strong) NSNumber *functionID;

- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
	// 1. LOG DI ENTRATA: Se vedi questo, l'hook sulla classe MTRequest funziona.
    customLog(@"[TGExtra] setPayload chiamato per functionID...");
	
	// Extract Function id 
	int32_t functionID;
	[payload getBytes:&functionID length:4];
	self.functionID = [NSNumber numberWithInt:functionID];
	
	id(^hooked_block)(NSData *) = ^id(NSData *inputData) {
		// --- LOGICA ANTI-DELETE IN ENTRATA ---
		if (inputData.length >= 4) {
			int32_t responseID;
			[inputData getBytes:&responseID length:4];
			
			// Log di debug per vedere TUTTI i pacchetti in arrivo (utile per trovare nuovi ID)
			customLog(@"[TGExtra] DEBUG: Pacchetto in arrivo ID: %d", responseID);

			// --- LOGICA ANTI-DELETE IN ENTRATA ---
			if ([[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete]) {
				if (responseID == kUpdateDeleteMessages || responseID == kUpdateDeleteChannelMessages) {
					customLog(@"[TGExtra] SUCCESS: Bloccato comando di eliminazione dal server (ID: %d)", responseID);
					return nil; 
				}
			}
		} else {
			customLog(@"[TGExtra] DEBUG: Ricevuto pacchetto troppo corto per contenere un ID.");
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
	BOOL shouldHook = [[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction] || 
					  [[NSUserDefaults standardUserDefaults] boolForKey:kEnableAntiDelete];

	if (shouldHook) {
		customLog(@"[TGExtra] Hooking attivo con hooked_block.");
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
