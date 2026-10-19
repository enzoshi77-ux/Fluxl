#ifndef NBF_OBJC_MESSAGE_H
#define NBF_OBJC_MESSAGE_H

#include <objc/objc.h>

// Cast at the call site to the exact signature being sent.
id objc_msgSend(id self, SEL op, ...);

#endif
