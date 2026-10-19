#ifndef NBF_STUB_UIKIT_H
#define NBF_STUB_UIKIT_H

#import <Foundation/Foundation.h>

@interface NSUUID : NSObject
- (NSString *)UUIDString;
@end

@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
- (NSUUID *)identifierForVendor;
@end

#endif
