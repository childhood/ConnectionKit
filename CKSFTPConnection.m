//
//  SFTPConnection.m
//  CocoaSFTP
//
//  Created by Brian Amerige on 11/4/07.
//  Copyright 2007 Extendmac, LLC.. All rights reserved.
//

#import "CKSFTPConnection.h"
#import "CKSFTPTServer.h"

#import "CKConnectionThreadManager.h"
#import "RunLoopForwarder.h"
#import "CKTransferRecord.h"
#import "CKInternalTransferRecord.h"
#import "EMKeychainProxy.h"
#import "CKFTPConnection.h"
#import "CKConnectionProtocol.h"
#import "NSURL+Connection.h"

#import "NSFileManager+Connection.h"
#import "NSString+Connection.h"

#include "fdwrite.h"

@interface CKSFTPConnection (Private)
- (void)_writeSFTPCommandWithString:(NSString *)commandString;
- (void)_handleFinishedCommand:(CKConnectionCommand *)command serverErrorResponse:(NSString *)errorResponse;
//
- (void)_finishedCommandInConnectionAwaitingCurrentDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionChangingDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionCreateDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionAwaitingRenameState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionSettingPermissionState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionDeleteFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionDeleteDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionUploadingFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
- (void)_finishedCommandInConnectionDownloadingFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse;
//
- (CKTransferRecord *)uploadFile:(NSString *)localPath 
						  orData:(NSData *)data 
						  offset:(unsigned long long)offset 
					  remotePath:(NSString *)remotePath
			checkRemoteExistence:(BOOL)flag
						delegate:(id)delegate;
- (void)uploadDidBegin:(CKInternalTransferRecord *)uploadInfo;
//
- (void)passwordErrorOccurred;
@end


@interface CKSFTPConnection (Authentication)
//! @abstract Sends the username if we can possibly authenticate. If authentication has been attempted before, fails.
- (void)_authenticateConnection;
@end


#pragma mark -


@implementation CKSFTPConnection

NSString *CKSFTPErrorDomain = @"CKSFTPErrorDomain";
static NSString *lsform = nil;

#pragma mark -
#pragma mark Getting Started / Tearing Down
+ (void)load    // registration of this class
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	//Register all URL Schemes and the protocol.
	NSEnumerator *URLSchemeEnumerator = [[self URLSchemes] objectEnumerator];
	NSString *URLScheme;
	while ((URLScheme = [URLSchemeEnumerator nextObject]))
		[[CKConnectionRegistry sharedConnectionRegistry] registerClass:self forProtocol:[self protocol] URLScheme:URLScheme];

    [pool release];
}

+ (NSInteger)defaultPort { return 22; }

+ (CKProtocol)protocol
{
	return CKSFTPProtocol;
}

+ (NSArray *)URLSchemes
{
	return [NSArray arrayWithObjects:@"sftp", @"ssh", nil];
}

- (id)initWithRequest:(CKConnectionRequest *)request
{
	if ([[[request URL] host] length] == 0) // SFTP needs a hostname to connect to
    {
        [self release];
        return nil;
    }
    
    if ((self = [super initWithRequest:request]))
	{
		theSFTPTServer = [[CKSFTPTServer alloc] init];
		connectToQueue = [[NSMutableArray array] retain];
		currentDirectory = [[NSMutableString string] retain];
		attemptedKeychainPublicKeyAuthentications = [[NSMutableArray array] retain];
	}
	return self;
}

- (void)_setupConnectTimeOut
{
	//Set up a timeout for connecting. If we're not connected in 10 seconds, error!
	unsigned timeout = 10;
	NSNumber *defaultsValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"CKFTPDataConnectionTimeoutValue"];
	if (defaultsValue) {
		timeout = [defaultsValue unsignedIntValue];
	}
	
	_connectTimeoutTimer = [[NSTimer scheduledTimerWithTimeInterval:timeout
															 target:self
														   selector:@selector(_connectTimeoutTimerFire:)
														   userInfo:nil
															repeats:NO] retain];
}

- (void)dealloc
{
	[connectToQueue release];
	[currentDirectory release];
	[rootDirectory release];
	[attemptedKeychainPublicKeyAuthentications release];
	
	[super dealloc];
}

#pragma mark -
#pragma mark Accessors

- (int)masterProxy { return masterProxy; }

- (void)setMasterProxy:(int)proxy
{
	masterProxy = proxy;
}

#pragma mark -
#pragma mark Connecting

- (void)connect
{
	[[[CKConnectionThreadManager defaultManager] prepareWithInvocationTarget:self] threadedConnect];
}

- (void)threadedConnect
{
	if (_isConnecting || [self isConnected]) return;
    
    
	_isConnecting = YES;
	
    // Can't connect till we have a password (due to using the SFTP command-line tool)
    [self _authenticateConnection];
}

/*  Support method. Called once the delegate has provided a username to connect with
 */
- (void)connectWithUsername:(NSString *)username
{
    NSAssert(username, @"Can't create an SFTP connection without a username");
    
    NSMutableArray *parameters = [NSMutableArray array];
	BOOL enableCompression = NO; // We do support this on the backend, but we have no UI for it yet.
	if (enableCompression)
		[parameters addObject:@"-C"];
	
    // Port
    if ([[[self request] URL] port])
    {
		[parameters addObject:[NSString stringWithFormat:@"-o Port=%i", [self port]]];
    }
    
    // Logging Level
    NSUInteger loggingLevel = [[self request] SFTPLoggingLevel];
    if (loggingLevel > 0)
    {
        [parameters addObject:[@"-" stringByPaddingToLength:(loggingLevel + 1)
                                                 withString:@"v"
                                            startingAtIndex:0]];
    }
    
    // Authentication
	NSString *password = [[[self request] URL] originalUnescapedPassword];
	if (password && [password length] > 0)
    {
		[parameters addObject:@"-o PubkeyAuthentication=no"];
    }
	else
	{
		NSString *publicKeyPath = [[self request] SFTPPublicKeyPath];
		if (publicKeyPath && [publicKeyPath length] > 0)
			[parameters addObject:[NSString stringWithFormat:@"-o IdentityFile=%@", publicKeyPath]];
		else
		{
			[parameters addObject:[NSString stringWithFormat:@"-o IdentityFile=~/.ssh/%@", username]];
			[parameters addObject:@"-o IdentityFile=~/.ssh/id_rsa"];
			[parameters addObject:@"-o IdentityFile=~/.ssh/id_dsa"];
		}
	}
	[parameters addObject:[NSString stringWithFormat:@"%@@%@", username, [[[self request] URL] host]]];
	
	switch ([CKSFTPTServer SFTPListingForm])
	{
		case SFTPListingUnsupported:
			//Not Supported.
			return;
		case SFTPListingLongForm:
			lsform = @"ls -l";
			break;
			
		case SFTPListingExtendedLongForm:
			lsform = @"ls -la";
			break;
			
		case SFTPListingShortForm:
		default:
			lsform = @"ls";
			break;
    }
	
	
	[self _setupConnectTimeOut];
	[self setState:CKConnectionNotConnectedState];
	[NSThread detachNewThreadSelector:@selector(_threadedSpawnSFTPTeletypeServer:) toTarget:self withObject:parameters];
}
- (void)_threadedSpawnSFTPTeletypeServer:(NSArray *)parameters
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	if (theSFTPTServer)
	{
		[theSFTPTServer release];
		theSFTPTServer = nil;
	}
	
	theSFTPTServer = [[CKSFTPTServer alloc] init];	
	[theSFTPTServer connectToServerWithArguments:parameters forWrapperConnection:self];
	
	[pool release];
}

#pragma mark -
#pragma mark Disconnecting
- (void)disconnect
{
	[[[CKConnectionThreadManager defaultManager] prepareWithInvocationTarget:self] threadedDisconnect];
}

- (void)threadedDisconnect
{
	CKConnectionCommand *quit = [CKConnectionCommand command:@"quit"
											  awaitState:CKConnectionIdleState
											   sentState:CKConnectionSentDisconnectState
											   dependant:nil
												userInfo:nil];
	[self queueCommand:quit];
}

- (void)forceDisconnect
{
	[[[CKConnectionThreadManager defaultManager] prepareWithInvocationTarget:self] threadedForceDisconnect];
}

- (void)threadedForceDisconnect
{
	[self didDisconnect];
}


#pragma mark -
#pragma mark Directory Changes
- (NSString *)rootDirectory
{
	return rootDirectory;
}

- (NSString *)currentDirectory
{
	return [NSString stringWithString:currentDirectory];
}

- (void)changeToDirectory:(NSString *)newDir
{
	CKConnectionCommand *pwd = [CKConnectionCommand command:@"pwd" 
											 awaitState:CKConnectionIdleState
											  sentState:CKConnectionAwaitingCurrentDirectoryState
											  dependant:nil
											   userInfo:nil];
	CKConnectionCommand *cd = [CKConnectionCommand command:[NSString stringWithFormat:@"cd \"%@\"", newDir]
											awaitState:CKConnectionIdleState
											 sentState:CKConnectionChangingDirectoryState
											 dependant:pwd
											  userInfo:nil];
	[self queueCommand:cd];
	[self queueCommand:pwd];
}

- (void)contentsOfDirectory:(NSString *)dirPath
{
	NSParameterAssert(dirPath);
	
	//Users can explicitly request we not cache directory listings. Are we allowed to?
	BOOL cachingDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:CKDoesNotCacheDirectoryListingsKey];
	if (!cachingDisabled)
	{
		//We're allowed to cache directory listings. Return a cached listing if possible.
		NSArray *cachedContents = [self cachedContentsWithDirectory:dirPath];
		if (cachedContents)
		{
			[[self client] connectionDidReceiveContents:cachedContents ofDirectory:dirPath error:nil];
			
			//By default, we automatically refresh the cached listings after returning the cached version. Users can explicitly request we not do this.
			if ([[NSUserDefaults standardUserDefaults] boolForKey:CKDoesNotRefreshCachedListingsKey])
				return;
		}		
	}
	
	[self changeToDirectory:dirPath];
	[self directoryContents];
	[self changeToDirectory:currentDirectory];
}

- (void)directoryContents
{
	CKConnectionCommand *ls = [CKConnectionCommand command:lsform
											awaitState:CKConnectionIdleState
											 sentState:CKConnectionAwaitingDirectoryContentsState
											 dependant:nil
											  userInfo:nil];
	[self queueCommand:ls];
}

#pragma mark -
#pragma mark File Manipulation
- (void)createDirectory:(NSString *)newDirectoryPath
{
	NSAssert(newDirectoryPath && ![newDirectoryPath isEqualToString:@""], @"no directory specified");
	
	CKConnectionCommand *mkd = [CKConnectionCommand command:[NSString stringWithFormat:@"mkdir \"%@\"", newDirectoryPath]
											 awaitState:CKConnectionIdleState
											  sentState:CKConnectionCreateDirectoryState
											  dependant:nil
											   userInfo:nil];
	[self queueCommand:mkd];
}

- (void)createDirectory:(NSString *)newDirectoryPath permissions:(unsigned long)permissions
{
	[self createDirectory:newDirectoryPath];
	[self setPermissions:permissions forFile:newDirectoryPath];
}

- (void)rename:(NSString *)fromPath to:(NSString *)toPath
{
	NSAssert(fromPath && ![fromPath isEqualToString:@""], @"fromPath is nil!");
	NSAssert(toPath && ![toPath isEqualToString:@""], @"toPath is nil!");
	
	[self queueRename:fromPath];
	[self queueRename:toPath];
	
	CKConnectionCommand *rename = [CKConnectionCommand command:[NSString stringWithFormat:@"rename \"%@\" \"%@\"", fromPath, toPath]
												awaitState:CKConnectionIdleState
												 sentState:CKConnectionAwaitingRenameState
												 dependant:nil
												  userInfo:nil];
	[self queueCommand:rename];
}

- (void)setPermissions:(unsigned long)permissions forFile:(NSString *)path
{
	NSAssert(path && ![path isEqualToString:@""], @"no file/path specified");
	
	[self queuePermissionChange:path];
	CKConnectionCommand *chmod = [CKConnectionCommand command:[NSString stringWithFormat:@"chmod %lo \"%@\"", permissions, path]
											   awaitState:CKConnectionIdleState
												sentState:CKConnectionSettingPermissionsState
												dependant:nil
												 userInfo:nil];
	[self queueCommand:chmod];
}

#pragma mark -
#pragma mark Uploading

- (CKTransferRecord *)_uploadFile:(NSString *)localPath  toFile:(NSString *)remotePath checkRemoteExistence:(BOOL)flag  delegate:(id)delegate
{
	NSAssert(localPath && ![localPath isEqualToString:@""], @"localPath is nil!");
	NSAssert(remotePath && ![remotePath isEqualToString:@""], @"remotePath is nil!");
	
	return [self uploadFile:localPath
					 orData:nil
					 offset:0
				 remotePath:remotePath
	   checkRemoteExistence:flag
				   delegate:delegate];
}

- (CKTransferRecord *)uploadFile:(NSString *)localPath orData:(NSData *)data offset:(unsigned long long)offset remotePath:(NSString *)remotePath checkRemoteExistence:(BOOL)checkRemoteExistenceFlag delegate:(id)delegate
{
	if (!localPath)
		localPath = [remotePath lastPathComponent];
	if (!remotePath)
		remotePath = [[self currentDirectory] stringByAppendingPathComponent:[localPath lastPathComponent]];
	
	unsigned long long uploadSize = 0;
	if (data)
	{
		uploadSize = [data length];
		
		//Super Über Cheap Way Until I figure out how to do this in a pretty way.
		NSString *temporaryParentPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ConnectionKitTemporary"];
		[[NSFileManager defaultManager] recursivelyCreateDirectory:temporaryParentPath attributes:nil];
		
		static unsigned filenameCounter = 0;	// TODO: Make this counter threadsafe
		filenameCounter++;
		NSString *fileName = [NSString stringWithFormat:@"%u-%@", filenameCounter, [remotePath lastPathComponent]];
		
		localPath = [temporaryParentPath stringByAppendingPathComponent:fileName];
		[data writeToFile:localPath atomically:YES];
	}
	else
	{
		NSDictionary *attributes = [[NSFileManager defaultManager] fileAttributesAtPath:localPath traverseLink:YES];
		uploadSize = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
	}
	
	CKTransferRecord *record = [CKTransferRecord uploadRecordForConnection:self
														   sourceLocalPath:localPath
													 destinationRemotePath:remotePath
																	  size:uploadSize 
															   isDirectory:NO];
	id internalTransferRecordDelegate = (delegate) ? delegate : record;
		
	CKInternalTransferRecord *internalRecord = [CKInternalTransferRecord recordWithLocal:localPath data:data offset:offset remote:remotePath delegate:internalTransferRecordDelegate userInfo:record];
	
	[self queueUpload:internalRecord];
	
	CKConnectionCommand *upload = [CKConnectionCommand command:[NSString stringWithFormat:@"put \"%@\" \"%@\"", localPath, remotePath]
												awaitState:CKConnectionIdleState
												 sentState:CKConnectionUploadingFileState
												 dependant:nil
												  userInfo:nil];
	[self queueCommand:upload];
	return record;
}

- (CKTransferRecord *)uploadFromData:(NSData *)data toFile:(NSString *)remotePath checkRemoteExistence:(BOOL)flag delegate:(id)delegate
{
	NSAssert(data, @"no data");	// data should not be nil, but it shoud be OK to have zero length!
	NSAssert(remotePath && ![remotePath isEqualToString:@""], @"remotePath is nil!");
	
	return [self uploadFile:nil
					 orData:data
					 offset:0
				 remotePath:remotePath
	   checkRemoteExistence:flag
				   delegate:delegate];
}

#pragma mark -
#pragma mark Downloading

- (CKTransferRecord *)downloadFile:(NSString *)remotePath toDirectory:(NSString *)dirPath overwrite:(BOOL)flag delegate:(id)delegate
{
	NSAssert(remotePath && ![remotePath isEqualToString:@""], @"no remotePath");
	NSAssert(dirPath && ![dirPath isEqualToString:@""], @"no dirPath");
	
	NSString *remoteFileName = [remotePath lastPathComponent];
	NSString *localPath = [dirPath stringByAppendingPathComponent:remoteFileName];
	
	if (!flag && [[NSFileManager defaultManager] fileExistsAtPath:localPath])
	{
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  LocalizedStringInConnectionKitBundle(@"Local File already exists", @"FTP download error"), NSLocalizedDescriptionKey,
                                  remotePath, NSFilePathErrorKey, nil];
        NSError *error = [NSError errorWithDomain:CKSFTPErrorDomain code:FTPDownloadFileExists userInfo:userInfo];
        [[self client] connectionDidReceiveError:error];
		
		return nil;
	}
	
	CKTransferRecord *record = [CKTransferRecord downloadRecordForConnection:self
															sourceRemotePath:remotePath
														destinationLocalPath:localPath
																		size:0 
																 isDirectory:NO];
	
	CKInternalTransferRecord *internalTransferRecord = [CKInternalTransferRecord recordWithLocal:localPath
																							data:nil
																						  offset:0
																						  remote:remotePath
																						delegate:delegate ? delegate : record
																						userInfo:record];

	[self queueDownload:internalTransferRecord];
	
	CKConnectionCommand *download = [CKConnectionCommand command:[NSString stringWithFormat:@"get \"%@\" \"%@\"", remotePath, localPath]
												  awaitState:CKConnectionIdleState
												   sentState:CKConnectionDownloadingFileState
												   dependant:nil
													userInfo:nil];
	[self queueCommand:download];
	
	return record;
}

#pragma mark -
#pragma mark Deletion

- (void)deleteFile:(NSString *)remotePath
{
	NSAssert(remotePath && ![remotePath isEqualToString:@""], @"path is nil!");
	
	[self queueDeletion:remotePath];
	
	CKConnectionCommand *delete = [CKConnectionCommand command:[NSString stringWithFormat:@"rm \"%@\"", remotePath]
												awaitState:CKConnectionIdleState
												 sentState:CKConnectionDeleteFileState
												 dependant:nil
												  userInfo:nil];
	[self queueCommand:delete];
}

- (void)deleteDirectory:(NSString *)remotePath
{
	NSAssert(remotePath && ![remotePath isEqualToString:@""], @"remotePath is nil!");
	
	[self queueDeletion:remotePath];
	
	CKConnectionCommand *delete = [CKConnectionCommand command:[NSString stringWithFormat:@"rmdir \"%@\"", remotePath]
												awaitState:CKConnectionIdleState
												 sentState:CKConnectionDeleteDirectoryState
												 dependant:nil
												  userInfo:nil];
	[self queueCommand:delete];
}

#pragma mark -
#pragma mark Misc.

- (void)threadedCancelTransfer
{
	[self forceDisconnect];
	[self connect];
}

#pragma mark -
#pragma mark Command Queueing

- (void)sendCommand:(id)command
{
	[self _writeSFTPCommandWithString:command];
}

- (void)_writeSFTPCommand:(void *)cmd
{
	@synchronized (self)
	{
		if (!theSFTPTServer)
			return;
		size_t commandLength = strlen(cmd);
		if ( commandLength > 0 )
		{
			// Sandvox, at least, consistently gets -1 back after sending quit
			// this trap allows execution to continue
			// THIS MAY BE AN ISSUE FOR OTHER APPS
			BOOL isQuitCommand = (0 == strcmp(cmd, "quit"));
			ssize_t bytesWritten = write(masterProxy, cmd, strlen(cmd));
			if ( bytesWritten != commandLength && !isQuitCommand )
			{
				NSLog(@"_writeSFTPCommand: %@ failed writing command", [NSString stringWithUTF8String:cmd]);
			}
			
			commandLength = strlen("\n");
			bytesWritten = write(masterProxy, "\n", strlen("\n"));
			if ( bytesWritten != commandLength && !isQuitCommand )
			{
				NSLog(@"_writeSFTPCommand %@ failed writing newline", [NSString stringWithUTF8String:cmd]);
			}
		}
	}
}

- (void)_writeSFTPCommandWithString:(NSString *)commandString
{
	if (!commandString || ![commandString isKindOfClass:[NSString class]])
		return;
	if ([commandString isEqualToString:@"CONNECT"])
		return;
	if ([commandString hasPrefix:@"put"])
		[self uploadDidBegin:[self currentUpload]];
	else if ([commandString hasPrefix:@"get"])
		[self downloadDidBegin:[self currentDownload]];
	char *command = (char *)[commandString UTF8String];
	[self _writeSFTPCommand:command];
}

#pragma mark -

- (void)finishedCommand
{
	[self _handleFinishedCommand:[self lastCommand] serverErrorResponse:nil];
}

- (void)receivedErrorInServerResponse:(NSString *)serverResponse
{
	CKConnectionCommand *erroredCommand = [self lastCommand];
	[self _handleFinishedCommand:erroredCommand serverErrorResponse:serverResponse];
}

- (void)_handleFinishedCommand:(CKConnectionCommand *)command serverErrorResponse:(NSString *)errorResponse
{
	@synchronized (self)
	{
		CKConnectionState finishedState = GET_STATE;
			
		switch (finishedState)
		{
			case CKConnectionAwaitingCurrentDirectoryState:
				[self _finishedCommandInConnectionAwaitingCurrentDirectoryState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionChangingDirectoryState:
				[self _finishedCommandInConnectionChangingDirectoryState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionCreateDirectoryState:
				[self _finishedCommandInConnectionCreateDirectoryState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionAwaitingRenameState:
				[self _finishedCommandInConnectionAwaitingRenameState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionSettingPermissionsState:
				[self _finishedCommandInConnectionSettingPermissionState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionDeleteFileState:
				[self _finishedCommandInConnectionDeleteFileState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionDeleteDirectoryState:
				[self _finishedCommandInConnectionDeleteDirectoryState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionUploadingFileState:
				[self _finishedCommandInConnectionUploadingFileState:[command command] serverErrorResponse:errorResponse];
				break;
			case CKConnectionDownloadingFileState:
				[self _finishedCommandInConnectionDownloadingFileState:[command command] serverErrorResponse:errorResponse];
				break;
			default:
				break;
		}
		[self setState:CKConnectionIdleState];
	}
}

#pragma mark -

- (void)_finishedCommandInConnectionAwaitingCurrentDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	//We don't need to do anything beacuse SFTPTServer calls setCurrentDirectory on us.
}

- (void)_finishedCommandInConnectionChangingDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	//Typical Command string is			cd "/blah/blah/blah"
	NSRange pathRange = NSMakeRange(4, [commandString length] - 5);
	NSString *path = ([commandString length] > NSMaxRange(pathRange)) ? [commandString substringWithRange:pathRange] : nil;
	
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Failed to change to directory", @"Failed to change to directory");
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, path, NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];
	}
	
	[[self client] connectionDidChangeToDirectory:path error:error];	
}

- (void)_finishedCommandInConnectionCreateDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	//CommandString typically is	mkdir "/path/to/new/dir"
	NSRange pathRange = NSMakeRange(7, [commandString length] - 8); //8 chops off last quote too
	NSString *path = ([commandString length] > NSMaxRange(pathRange)) ? [commandString substringWithRange:pathRange] : nil;
	
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Create directory operation failed", @"Create directory operation failed");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, path, NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];
	}
	
	[[self client] connectionDidCreateDirectory:path error:error];
	
}

- (void)_finishedCommandInConnectionAwaitingRenameState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	NSString *fromPath = [_fileRenames objectAtIndex:0];
	NSString *toPath = [_fileRenames objectAtIndex:1];

	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Failed to rename file.", @"Failed to rename file.");
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, fromPath, @"fromPath", toPath, @"toPath", nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];		
	}
	
	[fromPath retain];
	[toPath retain];
	
	[_fileRenames removeObjectAtIndex:0];
	[_fileRenames removeObjectAtIndex:0];							 
	
	[[self client] connectionDidRename:fromPath to:toPath error:error];

	[fromPath release];
	[toPath release];
}

- (void)_finishedCommandInConnectionSettingPermissionState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = [NSString stringWithFormat:LocalizedStringInConnectionKitBundle(@"Failed to set permissions for path %@", @"SFTP Upload error"), [self currentPermissionChange]];
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
								  localizedDescription, NSLocalizedDescriptionKey, 
								  [self currentPermissionChange], NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];				
	}
	
	[[self client] connectionDidSetPermissionsForFile:[self currentPermissionChange] error:error];
	[self dequeuePermissionChange];
}

- (void)_finishedCommandInConnectionDeleteFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = [NSString stringWithFormat:@"%@: %@", LocalizedStringInConnectionKitBundle(@"Failed to delete file", @"couldn't delete the file"), [[self currentDirectory] stringByAppendingPathComponent:[self currentDeletion]]];
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, [self currentDeletion], NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];				
	}
	
	[[self client] connectionDidDeleteFile:[self currentDeletion] error:error];
	[self dequeueDeletion];
}

- (void)_finishedCommandInConnectionDeleteDirectoryState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = [NSString stringWithFormat:@"%@: %@", LocalizedStringInConnectionKitBundle(@"Failed to delete file", @"couldn't delete the file"), [[self currentDirectory] stringByAppendingPathComponent:[self currentDeletion]]];
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, [self currentDeletion], NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];				
	}
	
	[[self client] connectionDidDeleteDirectory:[self currentDeletion] error:error];
    
	[self dequeueDeletion];
}

- (void)_finishedCommandInConnectionUploadingFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Failed to upload file.", @"Failed to upload file.");
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, [[self currentUpload] remotePath], NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];				
	}
	
	CKInternalTransferRecord *upload = [[self currentUpload] retain]; 
	[self dequeueUpload];
	
	[[self client] uploadDidFinish:[upload remotePath] error:error];
	
    if ([upload delegateRespondsToTransferDidFinish])
		[[upload delegate] transferDidFinish:[upload userInfo] error:error];

	[upload release];
}

- (void)_finishedCommandInConnectionDownloadingFileState:(NSString *)commandString serverErrorResponse:(NSString *)errorResponse
{
	//We only act here if there is an error OR if the file we're downloaded finished without delivering progress (usually small files). We otherwise handle dequeueing and download notifications when the progress reaches 100.
	
	NSError *error = nil;
	if (errorResponse)
	{
		NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Failed to download file.", @"Failed to download file.");
		if ([errorResponse containsSubstring:@"permission"]) //Permission issue
			localizedDescription = LocalizedStringInConnectionKitBundle(@"Permission Denied", @"Permission Denied");
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:localizedDescription, NSLocalizedDescriptionKey, [[self currentDownload] remotePath], NSFilePathErrorKey, nil];
		error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];				
	}
	
	CKInternalTransferRecord *download = [[self currentDownload] retain]; 
	[self dequeueDownload];
	
	[[self client] downloadDidFinish:[download remotePath] error:error];
    
	if ([download delegateRespondsToTransferDidFinish])
		[[download delegate] transferDidFinish:[download userInfo] error:error];

    [[self client] connectionDidReceiveError:error];
	
	[download release];	
}

#pragma mark -
#pragma mark SFTPTServer Callbacks

- (void)didConnect
{
	if (_connectTimeoutTimer && [_connectTimeoutTimer isValid])
	{
		[_connectTimeoutTimer invalidate];
		[_connectTimeoutTimer release];
	}
	
	//Clear any failed pubkey authentications as we're now connected
	[attemptedKeychainPublicKeyAuthentications removeAllObjects];
	
	//Request the remote working directory
	CKConnectionCommand *getCurrentDirectoryCommand = [CKConnectionCommand command:@"pwd"
																	awaitState:CKConnectionIdleState
																	 sentState:CKConnectionAwaitingCurrentDirectoryState
																	 dependant:nil
																	  userInfo:nil];
	[self pushCommandOnCommandQueue:getCurrentDirectoryCommand];
}

- (void)_connectTimeoutTimerFire:(NSTimer *)timer
{
	NSAssert2(timer == _connectTimeoutTimer,
			  @"-[%@ %@] called with unexpected timer object",
			  NSStringFromClass([self class]),
			  NSStringFromSelector(_cmd));
	
	
	[_connectTimeoutTimer release];
	_connectTimeoutTimer = nil;
	
	
    NSString *localizedDescription = LocalizedStringInConnectionKitBundle(@"Timed Out waiting for remote host.", @"time out");
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                              localizedDescription, NSLocalizedDescriptionKey, 
                              [[[self request] URL] host], ConnectionHostKey, nil];
    
    NSError *error = [NSError errorWithDomain:CKSFTPErrorDomain code:StreamErrorTimedOut userInfo:userInfo];
    [[self client] connectionDidConnectToHost:[[[self request] URL] host] error:error];
}

- (void)didSetRootDirectory
{
	rootDirectory = [[NSString alloc] initWithString:currentDirectory];
	
	_isConnecting = NO;
	_isConnected = YES;
	
	[[self client] connectionDidConnectToHost:[[[self request] URL] host] error:nil];
	[[self client] connectionDidOpenAtPath:[NSString stringWithString:rootDirectory] authenticated:YES error:nil];
}

- (void)setCurrentDirectory:(NSString *)current
{
	[currentDirectory setString:current];
}

- (void)didDisconnect
{
	if (theSFTPTServer)
	{
		[theSFTPTServer release];
		theSFTPTServer = nil;
	}
		
	[attemptedKeychainPublicKeyAuthentications removeAllObjects];			
	
	_isConnected = NO;
	[[self client] connectionDidDisconnectFromHost:[[[self request] URL] host]];
}

- (void)didReceiveDirectoryContents:(NSArray*)items error:(NSError *)error
{
	if (!error)
	{
		//Cache the directory listings.
		[self cacheDirectory:currentDirectory withContents:items];
	}
	
	[[self client] connectionDidReceiveContents:items ofDirectory:[NSString stringWithString:currentDirectory] error:error];
}

- (void)upload:(CKInternalTransferRecord *)uploadInfo didProgressTo:(double)progressPercentage withEstimatedCompletionIn:(NSString *)estimatedCompletion givenTransferRateOf:(NSString *)rate amountTransferred:(unsigned long long)amountTransferred
{
	CKTransferRecord *record = [uploadInfo userInfo];
	NSNumber *progress = [NSNumber numberWithDouble:progressPercentage];
	
	if ([uploadInfo delegateRespondsToTransferProgressedTo])
		[[uploadInfo delegate] transfer:record progressedTo:progress];
	
    NSString *remotePath = [uploadInfo remotePath];
	[[self client] upload:remotePath didProgressToPercent:progress];
		
	
	if (progressPercentage != 100.0)
	{
		unsigned long long previousTransferred = [record transferred];
		
		//If we're reporting a negative chunkLength, return.
		if (amountTransferred < previousTransferred)
			return;
		else if (amountTransferred == previousTransferred)
		{
			//When the transferred amount exceeds 9999 KB, SFTP starts reporting progress in MB. Consequently, amountTransferred will be 10MB until 11 MB is hit. In this case, amountTransferred will not update. So to compensate, we calculate the *true* amount transferred by the progressPercentage.
			amountTransferred = ((progressPercentage / 100.0) * [record size]);
			
			//Note that to ensure a continuously *increasing* -transferred reading on the record, we leave chunkLength as zero 
			if (amountTransferred <= previousTransferred)
				return;
		}
		
		unsigned long long chunkLength = (amountTransferred - previousTransferred);
		
		if ([uploadInfo delegateRespondsToTransferTransferredData])
			[[uploadInfo delegate] transfer:record transferredDataOfLength:chunkLength];
	}
}

- (void)uploadDidBegin:(CKInternalTransferRecord *)uploadInfo
{
	if ([uploadInfo delegateRespondsToTransferDidBegin])
	{
		[[uploadInfo delegate] transferDidBegin:[uploadInfo userInfo]];
	}		
	
	NSString *remotePath = [uploadInfo remotePath];
	[[self client] uploadDidBegin:remotePath];
}

- (void)download:(CKInternalTransferRecord *)downloadInfo didProgressTo:(double)progressPercentage withEstimatedCompletionIn:(NSString *)estimatedCompletion givenTransferRateOf:(NSString *)rate amountTransferred:(unsigned long long)amountTransferred
{
	NSNumber *progress = [NSNumber numberWithDouble:progressPercentage];
	
	CKTransferRecord *record = [downloadInfo userInfo];
	
	if ([downloadInfo delegateRespondsToTransferProgressedTo])
	{
		[[downloadInfo delegate] transfer:record progressedTo:progress];
	}
	
	if (progressPercentage != 100.0)
	{
		unsigned long long previousTransferred = [record transferred];
		unsigned long long chunkLength = amountTransferred - previousTransferred;
		if ([downloadInfo delegateRespondsToTransferTransferredData])
		{
			[[downloadInfo delegate] transfer:record transferredDataOfLength:chunkLength];
		}
	}

	NSString *remotePath = [downloadInfo remotePath];
	[[self client] download:remotePath didProgressToPercent:progress];
}
- (void)downloadDidBegin:(CKInternalTransferRecord *)downloadInfo
{
	NSString *remotePath = [downloadInfo objectForKey:@"remotePath"];
	[[self client] downloadDidBegin:remotePath];
	
	if ([downloadInfo delegateRespondsToTransferDidBegin])
		[[downloadInfo delegate] transferDidBegin:[downloadInfo userInfo]];
}

#pragma mark -

- (void)requestPasswordWithPrompt:(char *)header
{
	NSString *password = [[[self request] URL] originalUnescapedPassword];
	if (password)
    {
        // Send the password to the server
        CKConnectionCommand *command = [CKConnectionCommand command:password
													     awaitState:CKConnectionIdleState
													      sentState:CKConnectionSentPasswordState
													      dependant:nil
													       userInfo:nil];
		[self pushCommandOnHistoryQueue:command];
		_state = [command sentState];
		[self sendCommand:[command command]];
    }
    else
	{
		//We're being asked for a password, and we don't have one. That means we were supposed to authenticate via public key and we failed. Calling _authenticateConnection will fail us appropriately since _hasAttemptedAuthentication is YES.
        [self _authenticateConnection];
	}
}

- (void)getContinueQueryForUnknownHost:(NSDictionary *)hostInfo
{
	//Authenticity of the host couldn't be established. yes/no scenario
	CKConnectionCommand *command = [CKConnectionCommand command:@"yes"
													 awaitState:CKConnectionIdleState
													  sentState:CKConnectionIdleState
													  dependant:nil
													   userInfo:nil];
	[self pushCommandOnHistoryQueue:command];
	_state = [command sentState];
	[self sendCommand:[command command]];
}

- (void)passphraseRequested:(NSString *)buffer
{
	//Typical Buffer: Enter passphrase for key '/Users/brian/.ssh/id_rsa': 
	
	NSString *pubKeyPath = [buffer substringWithRange:NSMakeRange(26, [buffer length]-29)];
	
	//Try to get it ourselves via keychain before asking client app for it
	EMGenericKeychainItem *item = [[EMKeychainProxy sharedProxy] genericKeychainItemForService:@"SSH" withUsername:pubKeyPath];
	if (item && [item password] && [[item password] length] > 0 && ![attemptedKeychainPublicKeyAuthentications containsObject:pubKeyPath])
	{
		[attemptedKeychainPublicKeyAuthentications addObject:pubKeyPath];
		CKConnectionCommand *command = [CKConnectionCommand command:[item password]
														 awaitState:CKConnectionIdleState
														  sentState:CKConnectionSentPasswordState
														  dependant:nil
														   userInfo:nil];
		[self pushCommandOnHistoryQueue:command];
		_state = [command sentState];
		[self sendCommand:[command command]];
		return;
	}
	
	//We don't have it on keychain, so ask the delegate for it if we can, or ask ourselves if not.	
	NSString *passphrase = [[self client] passphraseForHost:[[[self request] URL] host]
                                                   username:[[[self request] URL] user] publicKeyPath:pubKeyPath];
	
	if (passphrase)
	{
		CKConnectionCommand *command = [CKConnectionCommand command:passphrase
														 awaitState:CKConnectionIdleState
														  sentState:CKConnectionSentPasswordState
														  dependant:nil
														   userInfo:nil];
		[self pushCommandOnHistoryQueue:command];
		_state = [command sentState];
		[self sendCommand:[command command]];		
		return;
	}	
	
	[self passwordErrorOccurred];
}

- (void)passwordErrorOccurred
{
	//_hasAttemptedAuthentication is yes, so this will fail.
	[self _authenticateConnection];
}

@end


#pragma mark -
#pragma mark Authentication


@implementation CKSFTPConnection (Authentication)

- (void)_authenticateConnection
{
	//If we've already attempted authentication, our we don't have a user, fail.
	BOOL canAttemptAuthentication = (!_hasAttemptedAuthentication && [[[self request] URL] user] );
	if (!canAttemptAuthentication)
	{
		//Authentication information is wrong. Send an error and disconnect.
		NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:LocalizedStringInConnectionKitBundle(@"The connection failed to be authenticated properly. Check the username and password.", @"Authentication Failed"), NSLocalizedDescriptionKey, nil];
		NSError *error = [NSError errorWithDomain:CKSFTPErrorDomain code:0 userInfo:userInfo];
		[[self client] connectionDidOpenAtPath:nil authenticated:NO error:error];
		
		[self disconnect];
		
		return;		
	}
	
	//We only do this once before disconnecting.
	_hasAttemptedAuthentication = YES;
	
	[self connectWithUsername:[[[self request] URL] user]];
}

@end


#pragma mark -
#pragma mark CKConnectionRequest


@implementation CKConnectionRequest (CKSFTPConnection)

static NSString *CKSFTPPublicKeyPathKey = @"CKSFTPPublicKeyPath";
static NSString *CKSFTPLoggingLevelKey = @"CKSFTPLoggingLevel";

- (NSString *)SFTPPublicKeyPath { return [self propertyForKey:CKSFTPPublicKeyPathKey]; }

- (NSUInteger)SFTPLoggingLevel;
{
    return [[self propertyForKey:CKSFTPLoggingLevelKey] unsignedIntValue];
}

@end

@implementation CKMutableConnectionRequest (CKSFTPConnection)

- (void)setSFTPPublicKeyPath:(NSString *)path
{
	if (path)
		[self setProperty:path forKey:CKSFTPPublicKeyPathKey];
	else 
		[self removePropertyForKey:CKSFTPPublicKeyPathKey];
}

- (void)setSFTPLoggingLevel:(NSUInteger)level;
{
    [self setProperty:[NSNumber numberWithUnsignedInt:level] forKey:CKSFTPLoggingLevelKey];
}

@end