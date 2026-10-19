#ifndef NBF_OBJC_NSOBJCRUNTIME_H
#define NBF_OBJC_NSOBJCRUNTIME_H

#include <objc/objc.h>

typedef long NSInteger;
typedef unsigned long NSUInteger;

#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#define NS_OPTIONS(_type, _name) enum _name : _type _name; enum _name : _type

#define FOUNDATION_EXPORT extern

#endif
