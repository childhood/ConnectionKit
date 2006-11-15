//
//  ConnectionRegistry.h
//  Connection
//
//  Created by Greg Hulands on 15/11/06.
//  Copyright 2006 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

/*
 
		This class is used across applications to have a standard registry of known connections for 
		a user. This allows them to add/modify/delete connections they have and have them reflect in
		all applications that use the connection framework.
  
 */

@class CKHostCategory, CKBonjourCategory, CKHost;

@interface ConnectionRegistry : NSObject 
{
	NSMutableArray *myConnections;
	CKBonjourCategory *myBonjour;
	NSDistributedNotificationCenter *myCenter;
	NSLock *myLock;
}

+ (id)sharedRegistry; //use this. DO NOT alloc one yourself

- (void)addCategory:(CKHostCategory *)category;
- (void)removeCategory:(CKHostCategory *)category;

- (void)addConnection:(CKHost *)connection;
- (void)removeConnection:(CKHost *)connection;

- (NSArray *)connections;

@end
