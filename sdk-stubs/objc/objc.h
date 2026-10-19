// Minimal Objective-C runtime types for cross-compiling against iOS without
// Apple's SDK. Declarations only — every symbol resolves at load time against
// the runtime already present in the host app.
#ifndef NBF_OBJC_OBJC_H
#define NBF_OBJC_OBJC_H

#include <stddef.h>
#include <stdint.h>

typedef signed char BOOL;

#define YES ((BOOL)1)
#define NO  ((BOOL)0)

#ifndef nil
#define nil ((id)0)
#endif
#ifndef Nil
#define Nil ((Class)0)
#endif

typedef struct objc_class *Class;
typedef struct objc_object { Class isa; } *id;
typedef struct objc_selector *SEL;
typedef id (*IMP)(id, SEL, ...);

#endif
