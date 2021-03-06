//
//  ANEScopeChain.m
//  MangoFix
//
//  Created by jerry.yong on 2018/2/28.
//  Copyright © 2018年 yongpengliang. All rights reserved.
//

#import <objc/runtime.h>
#import "MFScopeChain.h"
#import "MFValue.h"
#import "MFBlock.h"
#import "MFPropertyMapTable.h"
#import "MFWeakPropertyBox.h"
#import "util.h"
#import "RunnerClasses+Execute.h"
#import "ORTypeVarPair+TypeEncode.h"
@interface MFScopeChain()
@property (strong,nonatomic)NSLock *lock;
@end
static MFScopeChain *instance = nil;
@implementation MFScopeChain
+ (instancetype)topScope{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [MFScopeChain new];
    });
    return instance;
}
+ (instancetype)scopeChainWithNext:(MFScopeChain *)next{
	MFScopeChain *scope = [MFScopeChain new];
	scope.next = next;
    scope.vars = [NSMutableDictionary dictionaryWithDictionary:next.vars];
	return scope;
}

- (instancetype)init{
	if (self = [super init]) {
		_vars = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
	}
	return self;
}

- (id)instance{
    MFScopeChain *scope = self;
    while (scope && ![scope getValueWithIdentifier:@"self"]) {
        scope = scope.next;
    }
    return [scope getValueWithIdentifier:@"self"].objectValue;
}
- (void)setValue:(MFValue *)value withIndentifier:(NSString *)identier{
    [self.lock lock];
    self.vars[identier] = value;
    [self.lock unlock];
}

- (MFValue *)getValueWithIdentifier:(NSString *)identifer{
    [self.lock lock];
	MFValue *value = self.vars[identifer];
    [self.lock unlock];
	return value;
}


const void *mf_propKey(NSString *propName) {
    static NSMutableDictionary *_propKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _propKeys = [[NSMutableDictionary alloc] init];
    });
    id key = _propKeys[propName];
    if (!key) {
        key = [propName copy];
        [_propKeys setObject:key forKey:propName];
    }
    return (__bridge const void *)(key);
}
- (NSString *)propNameByIvarName:(NSString *)ivarName{
    if (ivarName.length < 2) {
        return nil;
    }
    
    if (![ivarName hasPrefix:@"_"]) {
        return nil;
    }
    
    return [ivarName substringFromIndex:1];
}

- (void)assignWithIdentifer:(NSString *)identifier value:(MFValue *)value{
	for (MFScopeChain *pos = self; pos; pos = pos.next) {
		if (pos.instance) {
            NSString *propName = [self propNameByIvarName:identifier];
            MFPropertyMapTable *table = [MFPropertyMapTable shareInstance];
            Class clazz = object_getClass(pos.instance);
            ORPropertyDeclare *propDef = [table getPropertyMapTableItemWith:clazz name:propName].property;
            Ivar ivar;
            if (propDef) {
                id associationValue = value;
                const char *type = propDef.var.typeEncode;
                if (*type == '@') {
                    associationValue = value.objectValue;
                }
                MFPropertyModifier modifier = propDef.modifier;
                if ((modifier & MFPropertyModifierMemMask) == MFPropertyModifierMemWeak) {
                    associationValue = [[MFWeakPropertyBox alloc] initWithTarget:value];
                }
                objc_AssociationPolicy associationPolicy = mf_AssociationPolicy_with_PropertyModifier(modifier);
                objc_setAssociatedObject(pos.instance, mf_propKey(propName), associationValue, associationPolicy);
            }else if((ivar = class_getInstanceVariable(object_getClass(pos.instance),identifier.UTF8String))){
                const char *ivarEncoding = ivar_getTypeEncoding(ivar);
                if (*ivarEncoding == '@') {
                    object_setIvar(pos.instance, ivar, value.objectValue);
                }else{
                    ptrdiff_t offset = ivar_getOffset(ivar);
                    void *ptr = (__bridge void *)(pos.instance) + offset;
                    [value writePointer:ptr typeEncode:ivarEncoding];
                }
                return;
                
            }
		}else{
			MFValue *srcValue = [pos getValueWithIdentifier:identifier];
			if (srcValue) {
                
				[srcValue assignFrom:value];
				return;
			}
		}
		
	}
}

- (MFValue *)getValueWithIdentifier:(NSString *)identifier endScope:(MFScopeChain *)endScope{
    MFScopeChain *pos = self;
    // FIX: while self == endScope, will ignore self
    do {
        if (pos.instance) {
            NSString *propName = [self propNameByIvarName:identifier];
            MFPropertyMapTable *table = [MFPropertyMapTable shareInstance];
            Class clazz = object_getClass(pos.instance);
            ORPropertyDeclare *propDef = [table getPropertyMapTableItemWith:clazz name:propName].property;
            Ivar ivar;
            if (propDef) {
                id propValue = objc_getAssociatedObject(pos.instance, mf_propKey(propName));
                const char *type = propDef.var.typeEncode;
                MFValue *value = propValue;
                if (!propValue) {
                    value = [MFValue defaultValueWithTypeEncoding:type];
                }else if(*type == '@'){
                    if ([propValue isKindOfClass:[MFWeakPropertyBox class]]) {
                        MFWeakPropertyBox *box = propValue;
                        MFValue *weakValue = box.target;
                        value = [MFValue valueWithObject:weakValue];
                    }else{
                        value = [MFValue valueWithObject:propValue];
                    }
                }
                return value;
                
            }else if((ivar = class_getInstanceVariable(object_getClass(pos.instance),identifier.UTF8String))){
                MFValue *value;
                const char *ivarEncoding = ivar_getTypeEncoding(ivar);
                if (*ivarEncoding == '@') {
                    id ivarValue = object_getIvar(pos.instance, ivar);
                    value = [MFValue valueWithObject:ivarValue];
                }else{
                    void *ptr = (__bridge void *)(pos.instance) +  ivar_getOffset(ivar);
                    value = [[MFValue alloc] initTypeEncode:ivarEncoding pointer:ptr];
                }
                return value;
            }
        }
        MFValue *value = [pos getValueWithIdentifier:identifier];
        if (value) {
            return value;
        }
        pos = pos.next;
    } while ((pos != endScope) && (self != endScope));
    return nil;
}

- (MFValue *)getValueWithIdentifierInChain:(NSString *)identifier{
    return [self getValueWithIdentifier:identifier endScope:nil];
}

- (void)setMangoBlockVarNil{
//    dispatch_async(dispatch_get_global_queue(0, 0), ^{
//        [self.lock lock];
//        NSArray *allValues = [self.vars allValues];
//        for (MFValue *value in allValues) {
//            if ([value isObject]) {
//                Class ocBlockClass = NSClassFromString(@"NSBlock");
//                if ([[value c2objectValue] isKindOfClass:ocBlockClass]) {
//                    struct MFSimulateBlock *blockStructPtr = (__bridge void *)value.objectValue;
//                    if (blockStructPtr->flags & BLOCK_CREATED_FROM_MFGO) {
//                        value.objectValue = nil;
//                    }
//                }
//            }
//        }
//        [self.lock unlock];
//    });
}
- (void)clear{
    _vars = [NSMutableDictionary dictionary];
    _lock = [[NSLock alloc] init];
}
@end

