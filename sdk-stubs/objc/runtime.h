#ifndef NBF_OBJC_RUNTIME_H
#define NBF_OBJC_RUNTIME_H

#include <objc/objc.h>
#include <objc/NSObjCRuntime.h>

typedef struct objc_method *Method;
typedef struct objc_ivar *Ivar;
typedef struct objc_property *objc_property_t;

// Associated object policies (objc/runtime.h values).
enum {
    OBJC_ASSOCIATION_ASSIGN           = 0,
    OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1,
    OBJC_ASSOCIATION_COPY_NONATOMIC   = 3,
    OBJC_ASSOCIATION_RETAIN           = 01401,
    OBJC_ASSOCIATION_COPY             = 01403
};

Class objc_getClass(const char *name);
Class objc_lookUpClass(const char *name);
int   objc_getClassList(Class *buffer, int bufferCount);
Class *objc_copyClassList(unsigned int *outCount);

const char *class_getName(Class cls);
Class       class_getSuperclass(Class cls);
BOOL        class_respondsToSelector(Class cls, SEL sel);

Method class_getInstanceMethod(Class cls, SEL name);
Method class_getClassMethod(Class cls, SEL name);
Method *class_copyMethodList(Class cls, unsigned int *outCount);
objc_property_t *class_copyPropertyList(Class cls, unsigned int *outCount);
const char *property_getName(objc_property_t property);
Class object_getClass(id object);
BOOL   class_addMethod(Class cls, SEL name, IMP imp, const char *types);

SEL         method_getName(Method m);
IMP         method_getImplementation(Method m);
const char *method_getTypeEncoding(Method m);
void        method_exchangeImplementations(Method m1, Method m2);

SEL         sel_registerName(const char *str);
const char *sel_getName(SEL sel);

void objc_setAssociatedObject(id object, const void *key, id value, uintptr_t policy);
id   objc_getAssociatedObject(id object, const void *key);

#endif
