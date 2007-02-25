// FiSHy, a plugin for Colloquy providing Blowfish encryption.
// Copyright (C) 2007  Henning Kiel
// 
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

#import "FiSHController.h"

#import "Models/JVChatMessage.h"
#import "Controllers/JVChatWindowController.h"
#import "Controllers/JVChatController.h"
#import "Panels/JVChatRoomPanel.h"
#import "Panels/JVDirectChatPanel.h"
#import "Chat Core/MVChatUser.h"
#import "Chat Core/MVChatConnection.h"
#import "Models/JVChatTranscript.h"

#import "FiSHSecretStore.h"
#import "FiSHBlowfish.h"
#import "FiSHEncryptionPrefs.h"
#import "NSString+FiSHyExtensions.h"
#import "FiSHMisc.h"


#define FiSHYDummyConnection @"FiSHYDummyConnection"

// Postfix of encrypted messages to mark them visibly for the user.
// TODO: Make this user-configurable.
#define FiSHEncryptedMessageMarker NSLocalizedString(@"Encrypted message", @"Encrypted message")
#define FiSHExpectedEncryptionMarker NSLocalizedString(@"Unencrypted message in encrypted room!", @"Unencrypted message in encrypted room!")
#define FiSHEncryptionOverriddenMarker NSLocalizedString(@"Encryption overridden", @"Encryption overridden")

// Prefix of outgoing messages which we should not encrypt.
// TODO: Make this user-configurable.
NSString *FiSHNonEncryptingPrefix = @"+p";

// Command used to trigger an automatic key exchange. Syntax: /keyx [nick]. If no nick is given, the nick from the current query is used.
NSString *FiSHKeyExchangeCommand = @"keyx";
// Command used to set a key manually. Syntax: /setkey [#channel/nick] newkey. Contrary to keys from automated key exchange, these will be saved to Keychain. If only one argument is given, will use it as key, and will try to deduce the #channel/nick from current view's target.
NSString *FiSHSetKeyCommand = @"setkey";
// Commands to set encryption preference for a chat-room/query
NSString *FiSHPreferEncCommand = @"enableEnc";
NSString *FiSHAvoidEncCommand = @"disableEnc";



@interface FiSHController (FiSHyPrivate)
- (void) joinedDirectChat:(JVDirectChatPanel *)directChat;
@end


@implementation FiSHController
#pragma mark MVChatPlugin
- (id)initWithManager:(MVChatPluginManager *) manager;
{
   if (self = [super init])
   {
      DLog(@"Loading FiSHy.");

      keyExchanger_ = [[FiSHKeyExchanger alloc] initWithDelegate:self];
      urlToConnectionCache_ = [[NSMutableDictionary alloc] init];
      blowFisher_ = [[FiSHBlowfish alloc] init];
      
      encPrefs_ = [[FiSHEncryptionPrefs alloc] init];
      
      // Add encryption setting notices to rooms and queries already open when we were loaded.
      NSSet *openChatPanels = [[NSClassFromString(@"JVChatController") defaultController] chatViewControllersKindOfClass:NSClassFromString(@"JVDirectChatPanel")];
      NSEnumerator *chatPanelsEnum = [openChatPanels objectEnumerator];
      JVDirectChatPanel *aChatPanel = nil;
      while ((aChatPanel = [chatPanelsEnum nextObject]))
      {
         [self joinedDirectChat:aChatPanel];
      }
   }
   return self;
}

- (void)dealloc;
{
   [blowFisher_ release];
   [urlToConnectionCache_ release];
   [keyExchanger_ release];
   
   [super dealloc];
}


#pragma mark FiSHKeyExchangerDelegate
- (void)sendPrivateMessage:(NSString *)message to:(NSString *)receiver on:(id)connectionURL;
{
   MVChatConnection *theConnection = [urlToConnectionCache_ objectForKey:connectionURL];
   [theConnection sendRawMessageWithFormat:[NSString stringWithFormat:@"NOTICE %@ :%@", receiver, message]];
}

- (void)outputStatusInformation:(NSString *)statusInfo forContext:(NSString *)chatContext on:(id)connectionURL;
{
   MVChatConnection *theConnection = [urlToConnectionCache_ objectForKey:connectionURL];
   MVChatUser *theUser = [theConnection chatUserWithUniqueIdentifier:chatContext];
   JVDirectChatPanel *thePanel = [[NSClassFromString(@"JVChatController") defaultController] chatViewControllerForUser:theUser 
                                                                                        ifExists:NO
                                                                                   userInitiated:NO];
   [thePanel addEventMessageToDisplay:statusInfo withName:@"KeyExchangeInfo" andAttributes:nil];
}

- (void)keyExchanger:(FiSHKeyExchanger *)keyExchanger finishedKeyExchangeFor:(NSString *)nickname onConnection:(id)connection succesfully:(BOOL)succesfully;
{
   // If the key exchange was succesfull, prefer encryption for that query.
   if (succesfully)
   {
      [self outputStatusInformation:NSLocalizedString(@"Encryption is enabled for this room.", @"Encryption is enabled for this room.") forContext:nickname on:connection];

      // TODO: Handle service correclty.
      [encPrefs_ setTemporaryPreference:FiSHEncPrefPreferEncrypted forService:nil account:nickname];
}
}

#pragma mark MVIRCChatConnectionPlugin

- (void) processIncomingMessageAsData:(NSMutableData *) message from:(MVChatUser *) sender to:(id) receiver attributes:(NSMutableDictionary *)msgAttributes;
{
   // We only support IRC connections.
   if (!FiSHIsIRCConnection([sender connection]))
      return;

   
   // If we received a notice, it is possible, that it's a key exchange request/response. Let the FiSHKeyExchanger decide this.
   if ([[msgAttributes objectForKey:@"notice"] boolValue])
   {
      MVChatConnection *theConnection = (MVChatConnection *)[sender connection];
      [urlToConnectionCache_ setObject:theConnection forKey:[[theConnection url] absoluteString]];
      BOOL isKeyExchangeMessage = [keyExchanger_ processPrivateMessageAsData:message 
                                                                        from:[sender nickname] 
                                                                          on:[[theConnection url] absoluteString]];
      if (isKeyExchangeMessage)
      {
         // FiSHKeyExchanger handled the notice for us, so make Colloquy ignore it.
         [message setLength:0];
         return;
      }
   }
   
   
   // Get the secret for the current room/nick and connection. If we don't have one, just display the message without changes.
   NSString *accountName = nil;
   NSString *secret = nil;
   // The receiver is either the local user, or a chat room.
   if ([receiver isKindOfClass:NSClassFromString(@"MVChatRoom")])
      accountName = FiSHNameForChatObject(receiver);
   else
      accountName = FiSHNameForChatObject(sender);
   if (!accountName)
   {
      DLog(@"Ignoring unsupported chat object type.");
      return;
   }
   // TODO: Handle service/connection correctly.
   secret = [[FiSHSecretStore sharedSecretStore] secretForService:nil account:accountName];
   if (!secret)
      return;
   
   // Try to decrypt the raw encrypted text.
   NSData *decryptedData = nil;
   switch ([blowFisher_ decodeData:message intoData:&decryptedData key:secret])
   {
      case FiSHCypherTextCut:
      case FiSHCypherSuccess:
         [message setData:decryptedData];
         [msgAttributes setObject:[NSNumber numberWithInt:FiSHCypherTextCut] forKey:@"FiSHyResult"];
         [msgAttributes setObject:[NSNumber numberWithBool:YES] forKey:@"decrypted"]; 
         break;
      case FiSHCypherBadCharacters:
      case FiSHCypherUnknownError:
      case FiSHCypherPlainText:
         [msgAttributes setObject:[NSNumber numberWithInt:FiSHCypherTextCut] forKey:@"FiSHyResult"];
         break;
      default:
         DLog(@"Unexpected/unknown blowfish result.");
   }
}

- (void) processOutgoingMessageAsData:(NSMutableData *) message to:(id) receiver attributes:(NSDictionary *)msgAttributes;
{
   // We only support IRC connection. As we don't know what receiver we get passed here, extra checks are performed.
   if (![receiver respondsToSelector:@selector(connection)])
      return;
   if (!FiSHIsIRCConnection([receiver connection]))
      return;
   

   // Check if the user has overridden encryption temporarily.
   if ([[msgAttributes objectForKey:@"sendUnencrypted"] boolValue])
      return;
   // Check if the message is for a target for which encryption is enabled.
   if (![[msgAttributes objectForKey:@"shouldEncrypt"] boolValue])
      return;

   
   NSString *errorMessage = nil;
   
   // Check if we have a secret for the current room/nick.
   NSString *accountName = FiSHNameForChatObject(receiver);
   if (!accountName)
   {
      DLog(@"Ignoring unsupported chat object type.");
      return;
   }
   // TODO: Handle service/connection correctly.
   NSString *secret = [[FiSHSecretStore sharedSecretStore] secretForService:nil account:accountName];
   if (!secret)
   {
      errorMessage = NSLocalizedString(@"Encryption is enabled, but you don't have a key. The message was not sent.", @"Encryption is enabled, but you don't have a key. The message was not sent.");
      goto bail;
   }
   
   // Try to encrypt the raw outgoing message.
   NSData *encryptedData = nil;
   [blowFisher_ encodeData:message intoData:&encryptedData key:secret];
   if (!encryptedData)
   {
      errorMessage = NSLocalizedString(@"Encrypting the message failed. The message was not sent.", @"Encrypting the message failed. The message was not sent.");
      goto bail;
   }
   [message setData:encryptedData];
   return;
   
bail:
   // If encryption failed for some reason, cancel sending the message, and tell the user.
   [message setLength:0];
   
   JVDirectChatPanel *thePanel = nil;
   if ([receiver isKindOfClass:NSClassFromString(@"MVChatRoom")])
      thePanel = [[NSClassFromString(@"JVChatController") defaultController] chatViewControllerForRoom:receiver 
                                                                                              ifExists:NO];
   else
      thePanel = [[NSClassFromString(@"JVChatController") defaultController] chatViewControllerForUser:receiver 
                                                                                              ifExists:NO
                                                                                         userInitiated:NO];
   [thePanel addEventMessageToDisplay:errorMessage withName:@"EncryptionFailedInfo" andAttributes:nil];
   
   return;
}

#pragma mark MVChatPluginDirectChatSupport

/// Called whenever a message gets added to a chat panel.
/**
 Based on the attributes the incoming message has, we change its appearance to the user here. For received messages we already had a chance to decrypt it, and if so, have set the @"decrypted" attribute. For messages of the local user the message already went through processOutgoingMessage:inView:, were attributes were set if the message should be encrypted later, or not.
 Received messages which were encrypted in a room for which encryption is avoided are marked, as well as unencrypted messages in a room for which encryption is preferred.
 Encrypted messages of the local user are marked if sent in a room for which encryption is avoided. 
 */
- (void)processIncomingMessage:(JVMutableChatMessage *)message inView:(id <JVChatViewController>)aView;
{
   // We only support IRC connection.
   if (!FiSHIsIRCConnection([aView connection]))
      return;
   
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }
   

   // Get the name of the chat object the message is directed at.
   NSString *accountName = FiSHNameForChatObject([view target]);
   if (!accountName)
   {
      DLog(@"Ignoring unsupported chat object type.");
      return;
   }
   
   // Prepare a string to mark the message if it either was encrypted in an encryption-avoiding context or unencrypted in an encryption-preferring context.
   // At two places we have to differentiate between received messages and messages from the local user. Received messages can have a @"decrypted"-attribute while local messages can have a @"shouldEncrypt"-attribute. The marker for unencrypted remote messages in an encryption-preferring context is different than for user-overridden encryption for local messages.
   NSString *messageMarker = nil;
   BOOL hasBeenOrWillBeEncrypted = [message senderIsLocalUser] ? [[message objectForKey:@"shouldEncrypt"] boolValue] : [[message objectForKey:@"decrypted"] boolValue];
   FiSHEncPrefKey encPref = [encPrefs_ preferenceForService:nil account:accountName];
   if (hasBeenOrWillBeEncrypted && encPref == FiSHEncPrefAvoidEncrypted)
   {
      messageMarker = FiSHEncryptedMessageMarker;
   } else if (!hasBeenOrWillBeEncrypted && encPref == FiSHEncPrefPreferEncrypted)
   {
      messageMarker = [message senderIsLocalUser] ? FiSHEncryptionOverriddenMarker : FiSHExpectedEncryptionMarker;
   } else
      return;
   
   NSTextStorage *body = [message body];
   [body appendAttributedString:[[[NSAttributedString alloc] initWithString:messageMarker 
                                                                 attributes:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                    [NSSet setWithObjects:@"error", @"encoding", nil], @"CSSClasses",
                                                                    nil]
      ] autorelease]];
}

/// Called whenever a message gets sent over a ChatViewController.
/**
 This is the first place we get in contact with an outgoing message. Depending on user's preferences regarding the channel/query the message was sent in we set its attributes, so that at the lower layer, in processOutgoingMessageAsData::: we can encrypt it.
 This method won't be called for message sent with one of the sendMessage: methods in Chat Core.
 */
- (void)processOutgoingMessage:(JVMutableChatMessage *)message inView:(id <JVChatViewController>)aView;
{
   // We only support IRC connection.
   if (!FiSHIsIRCConnection([aView connection]))
      return;
   
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }

   
   // Get the name of the chat object the message is directed at.
   NSString *accountName = FiSHNameForChatObject([view target]);
   if (!accountName)
   {
      DLog(@"Ignoring unsupported chat object type.");
      return;
   }
   
   // Check, if the user prefers encryption for this target. If so, mark the message, so that we can encrypt it later.
   // TODO: Handle service.
   FiSHEncPrefKey encPref = [encPrefs_ preferenceForService:nil account:accountName];
   if (encPref == FiSHEncPrefPreferEncrypted)
   {
      [message setObject:[NSNumber numberWithBool:YES] forKey:@"shouldEncrypt"];
   } else if (encPref == FiSHEncPrefAvoidEncrypted)
   {
      [message setObject:[NSNumber numberWithBool:YES] forKey:@"sendUnencrypted"];
   }
}


#pragma mark MVChatPluginRoomSupport

- (void) joinedRoom:(JVChatRoomPanel *) room;
{
   // We only support IRC connection.
   if (!FiSHIsIRCConnection([[room target] connection]))
      return;
   
   
   [self joinedDirectChat:room];
}


#pragma mark Command handlers

- (BOOL)processKeyExchangeCommandWithArguments:(NSAttributedString *)arguments toConnection:(MVChatConnection *)connection inView:(id <JVChatViewController>)aView;
{
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }

   
   NSString *argumentString = [arguments string];
   // If no argument has been given, try to deduce it from the current view. This only works for queries, as key exchange for channels is not supported.
   if (!argumentString || [argumentString length] <= 0)
   {
      if ([[view target] isKindOfClass:NSClassFromString(@"MVChatUser")])
         argumentString = [[view target] nickname];
      else
      {
         DLog(@"No argument provided to /keyx, aborting.");
         return YES;
      }
   }
   // Check if argument is a channel-name. If so, cancel.
   if ([argumentString hasPrefix:@"#"] || [argumentString hasPrefix:@"&"])
   {
      [view addEventMessageToDisplay:@"Key exchange is not supported for channels" withName:@"KeyExchangeUnsupportedForChannels" andAttributes:nil];
      DLog(@"Key exchange is only supported for nicknames, not for channels, aborting.");
      return YES;
   }
   
   // Everything's fine, start the key exchange.
   [urlToConnectionCache_ setObject:connection forKey:[[connection url] absoluteString]];
   [keyExchanger_ requestTemporarySecretFor:argumentString onConnection:[[connection url] absoluteString]];
   
   return YES;
}

- (BOOL)processSetKeyCommandWithArguments:(NSAttributedString *)arguments toConnection:(MVChatConnection *)connection inView:(id <JVChatViewController>)aView;
{
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }

   
   NSString *argumentString = [arguments string];
   NSArray *argumentList = [[arguments string] FiSH_arguments];
   NSString *secret = nil;
   NSString *account = nil;
   // If two arguments, proceed. If one, try to deduce target by current view's target. If anything else, abort.
   if (!argumentList || [argumentList count] <= 0)
   {
      DLog(@"SetKey expects exactly 2 arguments, aborting.");
      return YES;
   } else if ([argumentList count] == 1)
   {
      // If only one argument has been given, use that as secret, and try to deduce the account from the current view.
      account = FiSHNameForChatObject([view target]);
      if (!account)
      {
         // TODO: Put out notice to user.
         DLog(@"SetKey expects exactly 2 arguments, aborting.");
         return NO;
      }
      secret = [argumentList objectAtIndex:0];
   } else if ([argumentList count] == 2)
   {
      secret = [argumentList objectAtIndex:1];
      account = [argumentList objectAtIndex:0];
   }
   
   // Everything's fine, set the key.
   // TODO: Handle service/connection correctly.
   if (![[FiSHSecretStore sharedSecretStore] storeSecret:secret forService:nil account:account isTemporary:NO])
   {
      [view addEventMessageToDisplay:NSLocalizedString(@"Failed to save the key.", @"Failed to save the key.") withName:@"KeySaveError" andAttributes:nil];   
      return NO;
   }
   [view addEventMessageToDisplay:NSLocalizedString(@"Key saved to Keychain.", @"Key saved to Keychain.") withName:@"KeySavedToKeychain" andAttributes:nil];   
   
   [encPrefs_ setPreference:FiSHEncPrefPreferEncrypted forService:nil account:account];
   [view addEventMessageToDisplay:NSLocalizedString(@"Encryption is enabled for this room.", @"Encryption is enabled for this room.") withName:@"EncryptionEnabledForRoom" andAttributes:nil];   
   
   return YES;
}

- (BOOL)processSendUnecryptedCommandWithArguments:(NSAttributedString *)arguments toConnection:(MVChatConnection *)connection inView:(id <JVChatViewController>)aView;
{
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }

   
   JVMutableChatMessage *msg = [[[NSClassFromString(@"JVMutableChatMessage") alloc] initWithText:arguments sender:[connection localUser]] autorelease];
   [msg setObject:[NSNumber numberWithBool:YES] forKey:@"sendUnencrypted"];
   [view echoSentMessageToDisplay:msg];
   [view sendMessage:msg];
   
   return YES;
}

- (BOOL) processEncryptionPreferenceCommandWithArguments:(NSAttributedString *)arguments toConnection:(MVChatConnection *)connection inView:(id <JVChatViewController>)aView pref:(FiSHEncPrefKey)encPref;
{
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }
   
   
   NSArray *argumentList = [[arguments string] FiSH_arguments];
   NSString *targetName = nil;
   if ([argumentList count] == 1)
   {
      targetName = [argumentList objectAtIndex:0];
   } else if ([argumentList count] == 0)
   {
      targetName = [[view target] isKindOfClass:NSClassFromString(@"MVChatUser")] ? [[view target] nickname] : [[view target] name];
   } else
   {
      DLog(@"Command expects exactly 1 argument");
      return NO;
   }
   
   // TODO: Differenciate between services here.
   [encPrefs_ setPreference:encPref forService:nil account:targetName];
   
   switch (encPref)
   {
      case FiSHEncPrefPreferEncrypted:
         [view addEventMessageToDisplay:NSLocalizedString(@"Encryption is enabled for this room.", @"Encryption is enabled for this room.") withName:@"EncryptionEnabledForRoom" andAttributes:nil];
         break;
      case FiSHEncPrefAvoidEncrypted:
         [view addEventMessageToDisplay:NSLocalizedString(@"Encryption is disabled for this room.", @"Encryption is disabled for this room.") withName:@"EncryptionDisabledForRoom" andAttributes:nil];
         break;
      default:
         break;
   }
   
   return YES;
}

#pragma mark MVChatPluginCommandSupport

- (BOOL)processUserCommand:(NSString *) command withArguments:(NSAttributedString *) arguments toConnection:(MVChatConnection *) connection inView:(id <JVChatViewController>)aView;
{
   // We only support IRC connection.
   if (!FiSHIsIRCConnection(connection))
      return NO;
   
   // Make sure that aView really is a direct chat panel.
   JVDirectChatPanel *view = FiSHDirectChatPanelForChatViewController(aView);
   if (!view)
   {
      DLog(@"Ignoring unsupported chat controller type.");
      return;
   }
   
   
   // Check for correct command string.
   if ([command isEqualToString:FiSHKeyExchangeCommand])
      return [self processKeyExchangeCommandWithArguments:arguments toConnection:connection inView:view];
   if ([command isEqualToString:FiSHSetKeyCommand])
      return [self processSetKeyCommandWithArguments:arguments toConnection:connection inView:view];
   if ([command isEqualToString:FiSHNonEncryptingPrefix])
      return [self processSendUnecryptedCommandWithArguments:arguments toConnection:connection inView:view];
   if ([command isEqualToString:FiSHPreferEncCommand])
      return [self processEncryptionPreferenceCommandWithArguments:arguments toConnection:connection inView:view pref:FiSHEncPrefPreferEncrypted];
   if ([command isEqualToString:FiSHAvoidEncCommand])
      return [self processEncryptionPreferenceCommandWithArguments:arguments toConnection:connection inView:view pref:FiSHEncPrefAvoidEncrypted];
   
   return NO;
}


@end

@implementation FiSHController (FiSHyPrivate)

// TODO: implement the following in colloquy
#pragma mark MVDirectChatSupport (not yet implemented in Colloquy)

// TODO: Move this out of private category when implemented in colloquy.
- (void) joinedDirectChat:(JVDirectChatPanel *)directChat;
{
   JVDirectChatPanel *thePanel = [[NSClassFromString(@"JVChatController") defaultController] chatViewControllerForRoom:[directChat target]
                                                                                                              ifExists:NO];
   
   if ([encPrefs_ preferenceForService:nil account:[[directChat target] name]] == FiSHEncPrefPreferEncrypted)
      [thePanel addEventMessageToDisplay:NSLocalizedString(@"Encryption is enabled for this room.", @"Encryption is enabled for this room.") withName:@"EncryptionEnabledForRoom" andAttributes:nil];
   if ([encPrefs_ preferenceForService:nil account:[[directChat target] name]] == FiSHEncPrefAvoidEncrypted)
      [thePanel addEventMessageToDisplay:NSLocalizedString(@"Encryption is disabled for this room.", @"Encryption is disabled for this room.") withName:@"EncryptionDisabledForRoom" andAttributes:nil];
}

@end
