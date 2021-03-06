
#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#include <xpc/xpc.h>
#include <sys/xattr.h>

static xpc_object_t reloadRequest = NULL;

#define GlitterQuarantineAttributeName "com.apple.quarantine"

// borrowed from Sparkle
int GlitterRemoveXAttr(const char *name, NSString *file, int options) {
	const char *path = NULL;
	@try {
		path = [file fileSystemRepresentation];
	}
	@catch (id exception) {
		// -[NSString fileSystemRepresentation] throws an exception if it's
		// unable to convert the string to something suitable.  Map that to
		// EDOM, "argument out of domain", which sort of conveys that there
		// was a conversion failure.
		errno = EDOM;
		return -1;
	}

	return removexattr(path, name, options);
}

// borrowed from Sparkle
void GlitterReleaseFromQuarantine(NSString *root) {
	GlitterRemoveXAttr(GlitterQuarantineAttributeName, root, XATTR_NOFOLLOW);

	NSDictionary* rootAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:root error:nil];
	NSString* rootType = [rootAttributes objectForKey:NSFileType];

	if (rootType == NSFileTypeDirectory) {
		// The NSDirectoryEnumerator will avoid recursing into any contained
		// symbolic links, so no further type checks are needed.
		NSDirectoryEnumerator* directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtPath:root];
		NSString* file = nil;
		while ((file = [directoryEnumerator nextObject])) {
            GlitterRemoveXAttr(GlitterQuarantineAttributeName, [root stringByAppendingPathComponent:file], XATTR_NOFOLLOW);
		}
	}
}


BOOL GlitterVerifyCodeSignature(NSURL *oldBundle, NSURL *newBundle, NSError **outError) {
    OSStatus status = errSecSuccess;

    void (^handleError)(OSStatus status, NSString *action) = ^(OSStatus status, NSString *action) {
        NSString *errorDescription = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
        NSError *error = [NSError errorWithDomain:@"GlitterVerifyCodeSignature" code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %d - %@", action, status, errorDescription]}];
        if (outError)
            *outError = error;
        else
            NSLog(@"GlitterVerifyCodeSignature failed: %@", [error localizedDescription]);
    };

    SecStaticCodeRef oldCodeRef;
    status = SecStaticCodeCreateWithPath((__bridge CFURLRef)oldBundle, kSecCSDefaultFlags, &oldCodeRef);
    if (status != errSecSuccess) {
        handleError(status, @"Cannot load the previous version bundle (SecStaticCodeCreateWithPath failed)");
        return NO;
    }

    SecStaticCodeRef newCodeRef;
    status = SecStaticCodeCreateWithPath((__bridge CFURLRef)newBundle, kSecCSDefaultFlags, &newCodeRef);
    if (status != errSecSuccess) {
        handleError(status, @"Cannot load the new version bundle (SecStaticCodeCreateWithPath failed)");
        return NO;
    }

    SecRequirementRef requirementRef;
    status = SecCodeCopyDesignatedRequirement(oldCodeRef, kSecCSDefaultFlags, &requirementRef);
    if (status != errSecSuccess) {
        handleError(status, @"Cannot obtain designed requirements of the previous version (SecCodeCopyDesignatedRequirement)");
        return NO;
    }
                    
    status = SecStaticCodeCheckValidity(newCodeRef, kSecCSDefaultFlags, requirementRef);
    if (status != errSecSuccess) {
        handleError(status, @"The new version's code signature is invalid or does not meet the previous version's designated requirements");
        return NO;
    }

    return YES;
}


static void GlitterInstallationService_peer_event_handler(xpc_connection_t peer, xpc_object_t event) {
	xpc_type_t type = xpc_get_type(event);
	if (type == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INVALID || event == XPC_ERROR_TERMINATION_IMMINENT) {
            if (event == XPC_ERROR_CONNECTION_INVALID) {
                NSLog(@"GlitterInstallationService: XPC_ERROR_CONNECTION_INVALID");
            } else if (event == XPC_ERROR_TERMINATION_IMMINENT) {
                NSLog(@"GlitterInstallationService: XPC_ERROR_TERMINATION_IMMINENT");
            }
            if (reloadRequest) {
            }
		}
	} else {
		assert(type == XPC_TYPE_DICTIONARY);
        NSString *bundlePath = [NSString stringWithUTF8String:xpc_dictionary_get_string(event, "bundlePath")];
        NSString *updatePath = [NSString stringWithUTF8String:xpc_dictionary_get_string(event, "updatePath")];
        NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath];
        NSURL *updateURL = [NSURL fileURLWithPath:updatePath];

        NSLog(@"GlitterInstallationService: bundlePath = %@, updatePath = %@", bundlePath, updatePath);

//        xpc_connection_t remote = xpc_dictionary_get_remote_connection(event);
//        pid_t pid = xpc_connection_get_pid(remote);

        xpc_transaction_begin();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSLog(@"GlitterInstallationService: start of update installation");
            NSLog(@"GlitterInstallationService: previous version path: %@", bundlePath);
            NSLog(@"GlitterInstallationService: new version path: %@", updatePath);

            void (^completed)() = ^{
                xpc_transaction_end();
            };

            void (^failed)(NSString *action, NSError *error) = ^(NSString *action, NSError *inError){
                NSLog(@"GlitterInstallationService: %@: %@ - %ld - %@", action, inError.domain, (long)inError.code, inError.localizedDescription);
                
                NSError * __autoreleasing error;
                NSLog(@"GlitterInstallationService: deleting the invalid update bundle");
                BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:updatePath error:&error];
                if (!ok) {
                    NSLog(@"GlitterInstallationService: error deleting the invalid update bundle: %@ - %ld - %@", error.domain, (long)error.code, error.localizedDescription);
                }

                NSLog(@"GlitterInstallationService: launching old bundle");
                if ([[NSWorkspace sharedWorkspace] openFile:bundlePath]) {
                    NSLog(@"GlitterInstallationService: launching succeeded");
                } else {
                    NSLog(@"GlitterInstallationService: launching failed :-(");
                }
                completed();
            };

            NSLog(@"GlitterInstallationService: verifying code signature...");
            NSError * __autoreleasing error = nil;
            BOOL valid = GlitterVerifyCodeSignature(bundleURL, updateURL, &error);
            if (valid) {
                NSLog(@"GlitterInstallationService: code signature is valid.");
            } else {
                failed(@"Code signature not valid", error);
                return;
            }

            NSLog(@"GlitterInstallationService: releasing from quarantine...");
            GlitterReleaseFromQuarantine(updatePath);

            NSLog(@"GlitterInstallationService: moving the previous version to trash");
            [[NSWorkspace sharedWorkspace] recycleURLs:@[bundleURL] completionHandler:^(NSDictionary *newURLs, NSError *recyceError) {
                if (recyceError) {
                    failed(@"Error moving the previous version to trash", recyceError);
                    return;
                }

                NSError * __autoreleasing error;
                BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:updateURL toURL:bundleURL error:&error];
                if (!ok) {
                    failed(@"Error copying the new version over the previous one", error);
                    return;
                }

                NSLog(@"GlitterInstallationService: launching the updated app");
                if (![[NSWorkspace sharedWorkspace] openFile:bundlePath]) {
                    failed(@"Error launching the updated app", nil);
                    return;
                }

                NSLog(@"GlitterInstallationService: completed successfully.");
                completed();
            }];
        });
	}
}

static void GlitterInstallationService_event_handler(xpc_connection_t peer)  {
	xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
		GlitterInstallationService_peer_event_handler(peer, event);
	});
	
	xpc_connection_resume(peer);
}

int main(int argc, const char *argv[]) {
	xpc_main(GlitterInstallationService_event_handler);
	return 0;
}
