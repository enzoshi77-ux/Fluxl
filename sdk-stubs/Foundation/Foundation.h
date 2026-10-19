// Minimal Foundation surface used by NullsBotFill.m. Declarations only: the
// real Foundation supplies every implementation at runtime.
#ifndef NBF_STUB_FOUNDATION_H
#define NBF_STUB_FOUNDATION_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <objc/objc.h>
#include <objc/NSObjCRuntime.h>
#include <objc/runtime.h>

@class NSString, NSMutableString, NSArray, NSMutableArray, NSDictionary, NSNumber;

typedef NSInteger NSComparisonResult;
enum { NSOrderedAscending = -1, NSOrderedSame = 0, NSOrderedDescending = 1 };

__attribute__((objc_root_class))
@interface NSObject {
    Class isa;
}
+ (instancetype)alloc;
+ (instancetype)new;
+ (Class)class;
+ (BOOL)instancesRespondToSelector:(SEL)sel;
- (instancetype)init;
- (Class)class;
- (BOOL)isKindOfClass:(Class)cls;
- (BOOL)isMemberOfClass:(Class)cls;
- (BOOL)respondsToSelector:(SEL)sel;
- (id)performSelector:(SEL)sel;
- (id)performSelector:(SEL)sel withObject:(id)obj;
- (id)performSelector:(SEL)sel withObject:(id)o1 withObject:(id)o2;
- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;
- (id)valueForUndefinedKey:(NSString *)key;
- (void)setValue:(id)value forUndefinedKey:(NSString *)key;
- (NSString *)description;
@end

enum { NSUTF8StringEncoding = 4 };

@interface NSString : NSObject
+ (instancetype)string;
+ (instancetype)stringWithUTF8String:(const char *)s;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
- (instancetype)initWithFormat:(NSString *)fmt arguments:(va_list)args;
- (const char *)UTF8String;
- (NSUInteger)length;
- (BOOL)isEqualToString:(NSString *)other;
- (BOOL)containsString:(NSString *)s;
- (BOOL)localizedCaseInsensitiveContainsString:(NSString *)s;
- (NSComparisonResult)localizedCaseInsensitiveCompare:(NSString *)other;
- (NSString *)lowercaseString;
- (NSString *)stringByAppendingString:(NSString *)s;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)flag
           encoding:(NSUInteger)enc error:(id *)err;
@end

@interface NSMutableString : NSString
+ (instancetype)string;
- (void)appendString:(NSString *)s;
- (void)appendFormat:(NSString *)fmt, ...;
@end

NSString *NSTemporaryDirectory(void);
NSString *NSStringFromClass(Class cls);
NSString *NSStringFromSelector(SEL sel);
SEL NSSelectorFromString(NSString *name);
Class NSClassFromString(NSString *name);
void NSLog(NSString *fmt, ...);

@interface NSArray : NSObject
+ (instancetype)arrayWithObjects:(const id [])objects count:(NSUInteger)cnt;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)index;
- (id)firstObject;
- (BOOL)containsObject:(id)obj;
- (NSUInteger)countByEnumeratingWithState:(void *)state objects:(id *)buffer count:(NSUInteger)len;
- (NSMutableArray *)mutableCopy;
@end

@interface NSMutableArray : NSArray
+ (instancetype)array;
+ (instancetype)arrayWithCapacity:(NSUInteger)n;
- (void)addObject:(id)obj;
- (void)addObjectsFromArray:(NSArray *)other;
- (void)removeAllObjects;
- (void)removeObjectAtIndex:(NSUInteger)index;
@end

@interface NSSet : NSObject
@end

@interface NSMutableSet : NSSet
+ (instancetype)set;
- (void)addObject:(id)obj;
- (BOOL)containsObject:(id)obj;
@end

@interface NSDictionary : NSObject
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path;
+ (instancetype)dictionaryWithObjects:(const id [])objects
                              forKeys:(const id [])keys
                                count:(NSUInteger)cnt;
- (id)objectForKey:(id)key;
- (NSArray *)allKeys;
@end

@interface NSNumber : NSObject
+ (NSNumber *)numberWithBool:(BOOL)value;
+ (NSNumber *)numberWithInt:(int)value;
+ (NSNumber *)numberWithLong:(long)value;
+ (NSNumber *)numberWithUnsignedLong:(unsigned long)value;
+ (NSNumber *)numberWithUnsignedLongLong:(unsigned long long)value;
+ (NSNumber *)numberWithFloat:(float)value;
+ (NSNumber *)numberWithDouble:(double)value;
- (BOOL)boolValue;
- (int)intValue;
- (long)longValue;
- (long long)longLongValue;
- (unsigned long long)unsignedLongLongValue;
- (float)floatValue;
- (double)doubleValue;
@end

#endif
