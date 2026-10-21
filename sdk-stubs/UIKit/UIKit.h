#ifndef NBF_STUB_UIKIT_H
#define NBF_STUB_UIKIT_H

#import <Foundation/Foundation.h>

@interface NSUUID : NSObject
- (NSString *)UUIDString;
@end

@interface UIDevice : NSObject
+ (UIDevice *)currentDevice;
- (NSUUID *)identifierForVendor;
- (NSString *)systemVersion;
- (NSString *)model;
@end

// Used only by the crash-report alert. Everything is looked up at runtime and
// guarded, so a build without UIKit simply logs instead of presenting.
@interface UIWindow : NSObject
- (id)rootViewController;
@end

@interface UIViewController : NSObject
- (void)presentViewController:(id)viewController
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion;
@end

@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
- (NSArray *)windows;
@end

@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                         style:(NSInteger)style
                       handler:(void (^)(id action))handler;
@end

@interface UIAlertController : UIViewController
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end

@interface UIPasteboard : NSObject
+ (UIPasteboard *)generalPasteboard;
@property (nonatomic, copy) NSString *string;
@end

#endif
