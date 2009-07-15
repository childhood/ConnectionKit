//
//  CK_FileTransferClient.m
//  ConnectionKit
//
//  Created by Mike on 15/07/2009.
//  Copyright 2009 Karelia Software. All rights reserved.
//

#import "CK_FileTransferClient.h"

#import "CKConnectionAuthentication.h"
#import "CKThreadProxy.h"


@implementation CK_FileTransferClient

#pragma mark Init & Dealloc

- (id)initWithConnection:(CKFileTransferConnection *)connection
{
    [super init];
    
    _connection = connection;   // weak ref
    
    _threadProxy = [[CKThreadProxy CK_proxyWithTarget:connection thread:[NSThread currentThread]] retain];
    
    return self;
}

- (void)dealloc
{
    [_threadProxy release];
    [super dealloc];
}

#pragma mark Accessors

- (CKFileTransferConnection *)connection { return _connection; }

- (CKFileTransferProtocol *)connectionProtocol { return _protocol; }

- (void)setConnectionProtocol:(CKFileTransferProtocol *)protocol
{
    // This method should only be called the once, while setting up the stack
    NSParameterAssert(protocol);
    NSAssert1(!_protocol, @"%@ already has a protocol associated with it", self);
    
    
    _protocol = protocol;   // weak ref
}

- (CKFileTransferConnection *)connectionThreadProxy { return _threadProxy; }

#pragma mark Overall connection

/*  Sending a message directly from the worker thread to the delegate is a bad idea as it is
 *  possible the connection may have been cancelled by the time the message is delivered. Instead,
 *  deliver messages to ourself on the main thread and then forward them on to the delegate if
 *  appropriate.
 */

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol didOpenConnectionWithCurrentDirectoryPath:(NSString *)path
{
	NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    NSAssert([[self connection] status] == CKConnectionStatusOpening, @"The connection is not ready to be opened");  // This should never be called twice
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol didOpenConnectionWithCurrentDirectoryPath:path];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol didFailWithError:(NSError *)error;
{
	NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol didFailWithError:error];
}

#pragma mark Authorization

/*  Support method for filling an NSURLAuthenticationChallenge object. If no credential was supplied,
 *  looks for one from the connection's URL, and then falls back to using NSURLCredentialStorage.
 */
- (NSURLAuthenticationChallenge *)CK_fullAuthenticationChallengeForChallenge:(NSURLAuthenticationChallenge *)challenge
{
    NSURLAuthenticationChallenge *result = challenge;
    
    NSURLCredential *credential = [challenge proposedCredential];
    if (!credential)
    {
        NSURL *connectionURL = [[[self connection] request] URL];
        
        NSString *user = [connectionURL user];
        if (user)
        {
            NSString *password = [connectionURL password];
            if (password)
            {
                credential = [[[NSURLCredential alloc] initWithUser:user password:password persistence:NSURLCredentialPersistenceNone] autorelease];
            }
            else
            {
                credential = [[[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:[challenge protectionSpace]] objectForKey:user];
                if (!result)
                {
                    credential = [[[NSURLCredential alloc] initWithUser:user password:nil persistence:NSURLCredentialPersistenceNone] autorelease];
                }
            }
        }
        else
        {
            credential = [[NSURLCredentialStorage sharedCredentialStorage] defaultCredentialForProtectionSpace:[challenge protectionSpace]];
        }
        
        
        // Create a new request with the credential
        if (credential)
        {
            result = [[NSURLAuthenticationChallenge alloc] initWithAuthenticationChallenge:challenge
                                                                        proposedCredential:credential];
            [result autorelease];
        }
    }
    
    return result;
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
	NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    NSAssert([[self connection] status] > CKConnectionStatusNotOpen, @"The connection has not started yet");  // Should only happen while running
    
    
    // Fill in missing credentials if possible
    NSURLAuthenticationChallenge *fullChallenge = challenge;
    if (![challenge proposedCredential])
    {
        fullChallenge = [self CK_fullAuthenticationChallengeForChallenge:challenge];
    }
    
    
    // Does the delegate support this? If not, handle it ourselves
    id delegate = [[self connection] delegate];
    if ([delegate respondsToSelector:@selector(connection:didReceiveAuthenticationChallenge:)])
    {
        // Set up a proxy -sender object to forward the request to the main thread
        [[self connectionThreadProxy] fileTransferProtocol:protocol
                         didReceiveAuthenticationChallenge:fullChallenge];
    }
    else
    {
        NSURLCredential *credential = [fullChallenge proposedCredential];
        if ([credential user] && [credential hasPassword] && [challenge previousFailureCount] == 0)
        {
            [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
        }
        else
        {
            [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
        }
    }
}

#pragma mark Operation

- (void)fileTransferProtocolDidFinishCurrentOperation:(CKFileTransferProtocol *)protocol;
{
    NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    
    [[self connectionThreadProxy] fileTransferProtocolDidFinishCurrentOperation:protocol];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol currentOperationDidFailWithError:(NSError *)error;
{
    NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol currentOperationDidFailWithError:error];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol didDownloadData:(NSData *)data;
{
    NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol didDownloadData:data];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol didUploadDataOfLength:(NSUInteger)length;
{
    NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol didUploadDataOfLength:length];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol
        didReceiveProperties:(CKFileInfo *)fileInfo
                ofItemAtPath:(NSString *)path;
{
    NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol didReceiveProperties:fileInfo ofItemAtPath:path];
}

#pragma mark Transcript

/*	Convenience method for sending a string to the delegate for appending to the transcript
 */
- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol appendString:(NSString *)string toTranscript:(CKTranscriptType)transcript
{
	NSAssert2(protocol == [self connectionProtocol], @"-[CKFileTransferProtocolClient %@] message received from unknown protocol: %@", NSStringFromSelector(_cmd), protocol);
    
    [[self connectionThreadProxy] fileTransferProtocol:protocol appendString:string toTranscript:transcript];
}

- (void)fileTransferProtocol:(CKFileTransferProtocol *)protocol appendFormat:(NSString *)formatString toTranscript:(CKTranscriptType)transcript, ...
{
	va_list arguments;
	va_start(arguments, transcript);
	NSString *string = [[NSString alloc] initWithFormat:formatString arguments:arguments];
	va_end(arguments);
	
	[self fileTransferProtocol:protocol appendString:string toTranscript:transcript];
	[string release];
}

@end
