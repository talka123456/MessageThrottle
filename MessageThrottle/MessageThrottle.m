//
//  MessageThrottle.m
//  MessageThrottle
//
//  Created by 杨萧玉 on 2017/11/04.
//  Copyright © 2017年 杨萧玉. All rights reserved.
//

#import "MessageThrottle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#elif TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#endif

#if !__has_feature(objc_arc)
#error
#endif

// 判断对象是否是类对象还是实例对象
static inline BOOL mt_object_isClass(id _Nullable obj)
{
    if (!obj) return NO;
    if (@available(iOS 8.0, macOS 10.10, tvOS 9.0, watchOS 2.0, *)) {
        return object_isClass(obj);
    }
    else {
        // 实例对象的 class 返回对应的类对象， 类对象返回自身
        return obj == [obj class];
    }
}

// 通过 object_getClass 获取 meta class
Class mt_metaClass(Class cls)
{
    if (class_isMetaClass(cls)) {
        return cls;
    }
    return object_getClass(cls);
}

// block 操作掩码
enum {
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    BLOCK_HAS_CTOR =          (1 << 26), // helpers have C++ code
    BLOCK_IS_GLOBAL =         (1 << 28),
    BLOCK_HAS_STRET =         (1 << 29), // IFF BLOCK_HAS_SIGNATURE
    BLOCK_HAS_SIGNATURE =     (1 << 30),
};

// 模仿 block 数据结构
struct _MTBlockDescriptor
{
    unsigned long reserved;
    unsigned long size;
    // 指针类型的集合
    void *rest[1];
};

struct _MTBlock
{
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct _MTBlockDescriptor *descriptor;
};

/**
 获取 Block 签名
 struct Block_literal_1 {
     void *isa; // initialized to &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
     int flags;
     int reserved;
     void (*invoke)(void *, ...);
     struct Block_descriptor_1 {
         unsigned long int reserved;         // NULL
         unsigned long int size;         // sizeof(struct Block_literal_1)
         // optional helper functions
         void (*copy_helper)(void *dst, void *src);     // IFF (1<<25)
         void (*dispose_helper)(void *src);             // IFF (1<<25)
         // required ABI.2010.3.16
         const char *signature;                         // IFF (1<<30)
     } *descriptor;
     // imported variables
 };
 
 */
static const char * mt_blockMethodSignature(id blockObj)
{
    // 通过自定义的 Block 结构体桥接
    struct _MTBlock *block = (__bridge void *)blockObj;
    struct _MTBlockDescriptor *descriptor = block->descriptor;
    
    // 判断是否有签名
    assert(block->flags & BLOCK_HAS_SIGNATURE);
    
    int index = 0;
    // 根据Block_descriptor_1数据结构，如果有 copy & dispose 指针，则需要指针偏移两个索引才能获取到，依次是 copy、dispose、signature
    if(block->flags & BLOCK_HAS_COPY_DISPOSE)
        index += 2;
    
    return descriptor->rest[index];
}

// 对应销毁操作的实体对象， 通过关联对象绑定在对象本身，然后在实体类的 dealloc 中做移除操作， 这样对象销毁，自动移除绑定的 rule 等
@interface MTDealloc : NSObject

@property (nonatomic) MTRule *rule; //!< 关联的 rule 对象
@property (nonatomic) Class cls; //!< hook 后的类对象
@property (nonatomic) pthread_mutex_t invokeLock; //!< 递归锁， 在消息转发调用时使用

- (void)lock;
- (void)unlock;

@end

@implementation MTDealloc

- (instancetype)init
{
    self = [super init];
    if (self) {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_invokeLock, &attr);
    }
    return self;
}

- (void)dealloc
{
    // 调用discardRule:whenTargetDealloc: 函数释放 rule 对象
    // (void (*)(id, SEL, MTRule *, MTDealloc *))为强制类型转换,将[MTEngine.defaultEngine methodForSelector:selector]转化为函数指针
    // 函数默认都会有 id 和 SEl 参数
    // 然后填充参数调用
    SEL selector = NSSelectorFromString(@"discardRule:whenTargetDealloc:");
    ( (void (*)(id, SEL, MTRule *, MTDealloc *)) [MTEngine.defaultEngine methodForSelector:selector]) (MTEngine.defaultEngine, selector, self.rule, self);
}

- (void)lock
{
    pthread_mutex_lock(&_invokeLock);
}

- (void)unlock
{
    pthread_mutex_unlock(&_invokeLock);
}

@end

// rule 规则实体类， 为了
@interface MTRule () <NSSecureCoding>

@property (nonatomic) NSTimeInterval lastTimeRequest; //!< 上次实际发起请求的时间
@property (nonatomic) NSInvocation *lastInvocation; //!< 上次申请调用的 invocation对象， 用于last 模式下，超过durationThreshold调用
@property (nonatomic) SEL aliasSelector; //!< 原对象被 hook 的函数保存，实际是追加了_mt_前缀
@property (nonatomic, readwrite, getter=isActive) BOOL active; //!< 是否激活对象
@property (nonatomic, readwrite) id alwaysInvokeBlock; //!<是否总是调用 block 任务
@property (nonatomic, readwrite) dispatch_queue_t messageQueue; //!< 延迟调用，可以设置消息执行队列

@end

@implementation MTRule

- (instancetype)initWithTarget:(id)target selector:(SEL)selector durationThreshold:(NSTimeInterval)durationThreshold
{
    self = [super init];
    if (self) {
        _target = target;
        _selector = selector;
        _durationThreshold = durationThreshold;
        _mode = MTPerformModeDebounce;
        _lastTimeRequest = 0;
        _messageQueue = dispatch_get_main_queue();
    }
    return self;
}

#pragma mark Getter & Setter

- (SEL)aliasSelector
{
    if (!_aliasSelector) {
        NSString *selectorName = NSStringFromSelector(self.selector);
        _aliasSelector = NSSelectorFromString([NSString stringWithFormat:@"__mt_%@", selectorName]);
    }
    return _aliasSelector;
}

- (BOOL)isPersistent
{
    if (!mt_object_isClass(self.target)) {
        _persistent = NO;
    }
    return _persistent;
}

#pragma mark Public Method

- (BOOL)apply
{
    return [MTEngine.defaultEngine applyRule:self];
}

- (BOOL)discard
{
    return [MTEngine.defaultEngine discardRule:self];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"target:%@, selector:%@, durationThreshold:%f, mode:%lu", [self.target description], NSStringFromSelector(self.selector), self.durationThreshold, (unsigned long)self.mode];
}

#pragma mark Private Method

// 绑定在对象本身的Dealloc对象
- (MTDealloc *)mt_deallocObject
{
    MTDealloc *mtDealloc = objc_getAssociatedObject(self.target, self.selector);
    if (!mtDealloc) {
        mtDealloc = [MTDealloc new];
        mtDealloc.rule = self;
        mtDealloc.cls = object_getClass(self.target);
        objc_setAssociatedObject(self.target, self.selector, mtDealloc, OBJC_ASSOCIATION_RETAIN);
    }
    return mtDealloc;
}

#pragma mark NSSecureCoding

+ (BOOL)supportsSecureCoding
{
    return YES;
}

// 编码，用于持久化
- (void)encodeWithCoder:(NSCoder *)aCoder
{
    if (mt_object_isClass(self.target)) {
        Class cls = self.target;
        NSString *classKey = @"target";
        if (class_isMetaClass(cls)) {
            classKey = @"meta_target";
        }
        [aCoder encodeObject:NSStringFromClass(cls) forKey:classKey];
        [aCoder encodeObject:NSStringFromSelector(self.selector) forKey:@"selector"];
        [aCoder encodeDouble:self.durationThreshold forKey:@"durationThreshold"];
        [aCoder encodeObject:@(self.mode) forKey:@"mode"];
        [aCoder encodeDouble:self.lastTimeRequest forKey:@"lastTimeRequest"];
        [aCoder encodeBool:self.isPersistent forKey:@"persistent"];
        [aCoder encodeObject:NSStringFromSelector(self.aliasSelector) forKey:@"aliasSelector"];
    }
}

// 解码，
- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    id target = NSClassFromString([aDecoder decodeObjectOfClass:NSString.class forKey:@"target"]);
    if (!target) {
        target = NSClassFromString([aDecoder decodeObjectOfClass:NSString.class forKey:@"meta_target"]);
        target = mt_metaClass(target);
    }
    if (target) {
        SEL selector = NSSelectorFromString([aDecoder decodeObjectOfClass:NSString.class forKey:@"selector"]);
        NSTimeInterval durationThreshold = [aDecoder decodeDoubleForKey:@"durationThreshold"];
        
        // 无符号
        MTPerformMode mode = [[aDecoder decodeObjectForKey:@"mode"] unsignedIntegerValue];
        NSTimeInterval lastTimeRequest = [aDecoder decodeDoubleForKey:@"lastTimeRequest"];
        BOOL persistent = [aDecoder decodeBoolForKey:@"persistent"];
        NSString *aliasSelector = [aDecoder decodeObjectOfClass:NSString.class forKey:@"aliasSelector"];
        
        self = [self initWithTarget:target selector:selector durationThreshold:durationThreshold];
        self.mode = mode;
        self.lastTimeRequest = lastTimeRequest;
        self.persistent = persistent;
        self.aliasSelector = NSSelectorFromString(aliasSelector);
        return self;
    }
    return nil;
}

@end

// 对NSInvocation的一个封装
@interface MTInvocation ()

@property (nonatomic, weak, readwrite) NSInvocation *invocation;
@property (nonatomic, weak, readwrite) MTRule *rule;

@end

@implementation MTInvocation

@end

@interface MTEngine ()

@property (nonatomic) NSMapTable<id, NSMutableSet<NSString *> *> *targetSELs; //!<  记录 target <=> Set<Sel>的映射表，可以通过 target 查找到 sel,并通过 sel 查找到 dealloc 以及 dealloc.rule
@property (nonatomic) NSMutableSet<Class> *classHooked; //!< 记录所有被 hook 的类对象

- (void)discardRule:(MTRule *)rule whenTargetDealloc:(MTDealloc *)mtDealloc;

@end

@implementation MTEngine

static pthread_mutex_t mutex;
NSString * const kMTPersistentRulesKey = @"kMTPersistentRulesKey";

+ (instancetype)defaultEngine
{
    static dispatch_once_t onceToken;
    static MTEngine *instance;
    dispatch_once(&onceToken, ^{
        instance = [MTEngine new];
    });
    return instance;
}

+ (void)load
{
    // 读取持久化数据，
    NSArray<NSData *> *array = [NSUserDefaults.standardUserDefaults objectForKey:kMTPersistentRulesKey];
    for (NSData *data in array) {
        // 不同的
        if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *)) {
            NSError *error = nil;
            MTRule *rule = [NSKeyedUnarchiver unarchivedObjectOfClass:MTRule.class fromData:data error:&error];
            if (error) {
                NSLog(@"%@", error.localizedDescription);
            }
            else {
                [rule apply];
            }
        } else {
            @try {
                MTRule *rule = [NSKeyedUnarchiver unarchiveObjectWithData:data];
                [rule apply];
            } @catch (NSException *exception) {
                NSLog(@"%@", exception.description);
            }
        }
    }
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _targetSELs = [NSMapTable weakToStrongObjectsMapTable];
        _classHooked = [NSMutableSet set];
        pthread_mutex_init(&mutex, NULL);
        NSNotificationName name = nil;
#if TARGET_OS_IOS || TARGET_OS_TV
        name = UIApplicationWillTerminateNotification;
#elif TARGET_OS_OSX
        name = NSApplicationWillTerminateNotification;
#endif
        if (name.length > 0) {
            // 监听程序被杀死时的操作
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleAppWillTerminateNotification:) name:name object:nil];
        }
    }
    return self;
}

// 程序即将被杀死， 在这里做持久化
- (void)handleAppWillTerminateNotification:(NSNotification *)notification
{
    if (@available(macOS 10.11, *)) {
        [self savePersistentRules];
    }
}

// 保存持久化
- (void)savePersistentRules
{
    // 所有需要持久化的 rule 对象，进行编码操作
    NSMutableArray<NSData *> *array = [NSMutableArray array];
    for (MTRule *rule in self.allRules) {
        if (rule.isPersistent) {
            NSData *data;
            if (@available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *)) {
                NSError *error = nil;
                data = [NSKeyedArchiver archivedDataWithRootObject:rule requiringSecureCoding:YES error:&error];
                if (error) {
                    NSLog(@"%@", error.localizedDescription);
                }
            } else {
                data = [NSKeyedArchiver archivedDataWithRootObject:rule];
            }
            if (data) {
                [array addObject:data];
            }
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:array forKey:kMTPersistentRulesKey];
}

- (NSArray<MTRule *> *)allRules
{
    pthread_mutex_lock(&mutex);
    NSMutableArray *rules = [NSMutableArray array];
    for (id target in [[self.targetSELs keyEnumerator] allObjects]) {
        NSMutableSet *selectors = [self.targetSELs objectForKey:target];
        for (NSString *selectorName in selectors) {
            MTDealloc *mtDealloc = objc_getAssociatedObject(target, NSSelectorFromString(selectorName));
            if (mtDealloc.rule) {
                [rules addObject:mtDealloc.rule];
            }
        }
    }
    pthread_mutex_unlock(&mutex);
    return [rules copy];
}

/**
 添加 target-selector 记录

 @param selector 方法名
 @param target 对象，类，元类
 */
- (void)addSelector:(SEL)selector onTarget:(id)target
{
    if (!target) {
        return;
    }
    NSMutableSet *selectors = [self.targetSELs objectForKey:target];
    if (!selectors) {
        selectors = [NSMutableSet set];
    }
    [selectors addObject:NSStringFromSelector(selector)];
    [self.targetSELs setObject:selectors forKey:target];
}

/**
 移除 target-selector 记录
 
 @param selector 方法名
 @param target 对象，类，元类
 */
- (void)removeSelector:(SEL)selector onTarget:(id)target
{
    if (!target) {
        return;
    }
    NSMutableSet *selectors = [self.targetSELs objectForKey:target];
    if (!selectors) {
        selectors = [NSMutableSet set];
    }
    [selectors removeObject:NSStringFromSelector(selector)];
    [self.targetSELs setObject:selectors forKey:target];
}

/**
 是否存在 target-selector 记录

 @param selector 方法名
 @param target 对象，类，元类
 @return 是否存在记录
 */
- (BOOL)containsSelector:(SEL)selector onTarget:(id)target
{
    return [[self.targetSELs objectForKey:target] containsObject:NSStringFromSelector(selector)];
}

/**
 是否存在 target-selector 记录，未指定具体 target，但 target 的类型为 cls 即可

 @param selector 方法名
 @param cls 类
 @return 是否存在记录
 */
- (BOOL)containsSelector:(SEL)selector onTargetsOfClass:(Class)cls
{
    for (id target in [[self.targetSELs keyEnumerator] allObjects]) {
        if (!mt_object_isClass(target) &&
            object_getClass(target) == cls &&
            [[self.targetSELs objectForKey:target] containsObject:NSStringFromSelector(selector)]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)applyRule:(MTRule *)rule
{
    pthread_mutex_lock(&mutex);
    // 这里如果Target没有绑定 MTDealloc 关联对象， 创建新的对象并绑定， 函数结尾时如果 apple 失败，会置空
    MTDealloc *mtDealloc = [rule mt_deallocObject];
    [mtDealloc lock];
    BOOL shouldApply = YES;
    if (mt_checkRuleValid(rule)) {
        // 遍历存储的所有 target 和 sel  (target:[sel])， 这里选择遍历所有 rule 查找 selector 的方式，为什么不直接使用 rule.target 获取 selector呢，原因是需要检查继承链，而不仅仅是当前 target 本身
        for (id target in [[self.targetSELs keyEnumerator] allObjects]) {
            NSMutableSet *selectors = [self.targetSELs objectForKey:target];
            NSString *selectorName = NSStringFromSelector(rule.selector);
            if ([selectors containsObject:selectorName]) {
                if (target == rule.target) {
                    shouldApply = NO;
                    continue;
                }
                
                if (mt_object_isClass(rule.target) && mt_object_isClass(target)) {
                    // 针对类对象， 检测是否二者是子类关系， 是的话报错 即一条继承链上，相同的 rule 只能应用一次
                    Class clsA = rule.target;
                    Class clsB = target;
                    
                    //
                    shouldApply = !([clsA isSubclassOfClass:clsB] || [clsB isSubclassOfClass:clsA]);
                    // inheritance relationship
                    if (!shouldApply) {
                        NSLog(@"Sorry: %@ already apply rule in %@. A message can only have one rule per class hierarchy.", selectorName, NSStringFromClass(clsB));
                        break;
                    }
                }
                else if (mt_object_isClass(target) && target == object_getClass(rule.target)) {
                    // 如果已经在 target 类对象的实例中应用过规则， 则不能再次在类对象上应用
                    shouldApply = NO;
                    NSLog(@"Sorry: %@ already apply rule in target's Class(%@).", selectorName, target);
                    break;
                }
            }
        }
        shouldApply = shouldApply && mt_overrideMethod(rule);
        if (shouldApply) {
            // 添加到targetSELs
            [self addSelector:rule.selector onTarget:rule.target];
            rule.active = YES;
        }
    }
    else {
        shouldApply = NO;
        NSLog(@"Sorry: invalid rule.");
    }
    [mtDealloc unlock];
    if (!shouldApply) {
        // 如果提交失败， 则将 MTDealloc 置空 未使用objc_removeAssociatedObjects的原因是没办法针对特定的 key 做移除，只能全部移除
        objc_setAssociatedObject(rule.target, rule.selector, nil, OBJC_ASSOCIATION_RETAIN);
    }
    pthread_mutex_unlock(&mutex);
    return shouldApply;
}

// 废除指定的 rule
- (BOOL)discardRule:(MTRule *)rule
{
    // 二次加锁是为了防止在 discard 时， 其他线程改变 dealloc 对象
    pthread_mutex_lock(&mutex);
    MTDealloc *mtDealloc = [rule mt_deallocObject];
    [mtDealloc lock];
    BOOL shouldDiscard = NO;
    // 检查 rule 的有效性
    if (mt_checkRuleValid(rule)) {
        
        // 移除 Engine 单例中存储的对应 target 和 selector 的映射关系
        [self removeSelector:rule.selector onTarget:rule.target];
        shouldDiscard = mt_recoverMethod(rule.target, rule.selector, rule.aliasSelector);
        rule.active = NO;
    }
    [mtDealloc unlock];
    pthread_mutex_unlock(&mutex);
    return shouldDiscard;
}

// dealloc 对象在 target 释放时调用
- (void)discardRule:(MTRule *)rule whenTargetDealloc:(MTDealloc *)mtDealloc
{
    if (mt_object_isClass(rule.target)) {
        // 类对象不释放
        return;
    }
    pthread_mutex_lock(&mutex);
    [mtDealloc lock];
    if (![self containsSelector:rule.selector onTarget:mtDealloc.cls] &&
        ![self containsSelector:rule.selector onTargetsOfClass:mtDealloc.cls]) {
        mt_revertHook(mtDealloc.cls, rule.selector, rule.aliasSelector);
    }
    rule.active = NO;
    [mtDealloc unlock];
    pthread_mutex_unlock(&mutex);
}

#pragma mark - Private Helper Function

// 检查继承链上是否已经应用过 rule，
static BOOL mt_checkRuleValid(MTRule *rule)
{
    if (rule.target && rule.selector && rule.durationThreshold > 0) {
        // 检查 sel 是否为forwardInvocation 以及  rule 的target 是否为MTRule类或MTEngine类，说明已经 apple 过，
        NSString *selectorName = NSStringFromSelector(rule.selector);
        if ([selectorName isEqualToString:@"forwardInvocation:"]) {
            return NO;
        }
        Class cls = [rule.target class];
        NSString *className = NSStringFromClass(cls);
        if ([className isEqualToString:@"MTRule"] || [className isEqualToString:@"MTEngine"]) {
            return NO;
        }
        return YES;
    }
    return NO;
}

static BOOL mt_invokeFilterBlock(MTRule *rule, NSInvocation *originalInvocation)
{
    // 如果未设置或非 block 类型，return NO
    if (!rule.alwaysInvokeBlock || ![rule.alwaysInvokeBlock isKindOfClass:NSClassFromString(@"NSBlock")]) {
        return NO;
    }
    NSMethodSignature *filterBlockSignature = [NSMethodSignature signatureWithObjCTypes:mt_blockMethodSignature(rule.alwaysInvokeBlock)];
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:filterBlockSignature];
    NSUInteger numberOfArguments = filterBlockSignature.numberOfArguments;
    
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        NSLog(@"Block has too many arguments. Not calling %@", rule);
        return NO;
    }
    
    MTInvocation *invocation = nil;
    
    // invocation 默认 第零个位置是 self, 第一个位置是_cmd, 参数是从第二个位置开始
    // 但是 Block 比较特殊，  第零个参数是返回类型，第一个参数才是真正的参数
    // 默认第一个参数是 invocation 
    if (numberOfArguments > 1) {
        invocation = [MTInvocation new];
        invocation.invocation = originalInvocation;
        invocation.rule = rule;
        [blockInvocation setArgument:&invocation atIndex:1];
    }
    
    // 从第二个参数开始
    void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        // 获取指定位置参数的 EncodeType
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
        NSUInteger argSize;
        // 获取参数实际大小和对齐大小
        NSGetSizeAndAlignment(type, &argSize, NULL);
        
        // 创建堆内存空间，存放 Block 参数， 如果__ptr参数为 NULL, 则等同于 malloc()
        // 返回下一个位置指针，
        if (!(argBuf = reallocf(argBuf, argSize))) {
            NSLog(@"Failed to allocate memory for block invocation.");
            return NO;
        }
        
        // 获取指定位置的参数值存放到 argBuf buffer 内存空间，
        [originalInvocation getArgument:argBuf atIndex:idx];
        // 设置指定buffer 的值 给 Block的指定参数
        [blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    [blockInvocation invokeWithTarget:rule.alwaysInvokeBlock];
    BOOL returnedValue = NO;
    [blockInvocation getReturnValue:&returnedValue];
    
    // 释放 free 和 alloc 应该成对出现
    if (argBuf != NULL) {
        free(argBuf);
    }
    return returnedValue;
}

/**
 处理执行 NSInvocation

 @param invocation NSInvocation 对象
 @param rule MTRule 对象
 */
static void mt_handleInvocation(NSInvocation *invocation, MTRule *rule)
{
    NSCParameterAssert(invocation);
    NSCParameterAssert(rule);
    
    if (!rule.isActive) {
        // 如果规则不生效， 则直接调用，这里没有 invocation.selector = rule.aliasSelector; 的原因是 avtive == NO 只有在discord 时修改值，此时invovation.selector 已经恢复成了aliasSelector
        [invocation invoke];
        return;
    }
    
    // 如果间隔阈值 <=0 或者设置了 alwaysInvokeBlock并且返回YES,则立即执行原函数
    if (rule.durationThreshold <= 0 || mt_invokeFilterBlock(rule, invocation)) {
        invocation.selector = rule.aliasSelector;
        [invocation invoke];
        return;
    }
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 校正可能用户修改系统时间导致的差值
    now += MTEngine.defaultEngine.correctionForSystemTime;
    
    switch (rule.mode) {
        case MTPerformModeFirstly: {
            if (now - rule.lastTimeRequest > rule.durationThreshold) {
                invocation.selector = rule.aliasSelector;
                [invocation invoke];
                // 调用完成后清空invocation以及记录上次调用时间戳
                rule.lastTimeRequest = now;
                dispatch_async(rule.messageQueue, ^{
                    // May switch from other modes, set nil just in case.
                    rule.lastInvocation = nil;
                });
            }
            break;
        }
        case MTPerformModeLast: {
            invocation.selector = rule.aliasSelector;
            [invocation retainArguments];
            dispatch_async(rule.messageQueue, ^{
                // 每次请求都记录更新下次需要调用的 invocation
                rule.lastInvocation = invocation;
                
                // 如果和上次请求时间超过了阈值，则执行一次调用
                if (now - rule.lastTimeRequest > rule.durationThreshold) {
                    // 更新上次调用时间
                    rule.lastTimeRequest = now;
                    // 使用dispatch_after无需取消任务， throttle last 模式，每隔间隔时间调用一次
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rule.durationThreshold * NSEC_PER_SEC)), rule.messageQueue, ^{
                        // 考虑是延迟调用，此时可能 rule已经被 discord,所以判断并更新 invocation 的 selector
                        if (!rule.isActive) {
                            rule.lastInvocation.selector = rule.selector;
                        }
                        
                        
                        {
                            // 判断是否存在 isa class 被 recover 的情况， 如果被恢复了，则判断 rule.selector和 rule.aliasSelector 是否已经交换
                            
                            
                        }
                        
                        [rule.lastInvocation invoke];
                        rule.lastInvocation = nil;
                    });
                }
            });
            break;
        }
        case MTPerformModeDebounce: {
            invocation.selector = rule.aliasSelector;
            [invocation retainArguments];
            dispatch_async(rule.messageQueue, ^{
                rule.lastInvocation = invocation;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rule.durationThreshold * NSEC_PER_SEC)), rule.messageQueue, ^{
                    // 没次调用时都判断是否和上次保存的是一次调用 != 表示阈值间隔内又发起了调用， 则更新invocation即可，不发起请求
                    if (rule.lastInvocation == invocation) {
                        if (!rule.isActive) {
                            rule.lastInvocation.selector = rule.selector;
                        }
                        [rule.lastInvocation invoke];
                        rule.lastInvocation = nil;
                    }
                });
            });
            break;
        }
    }
}

// 所有消息最终都会转发到这里， invocation 携带了 target method 所有的信息 ？？？
// 该函数的目的即区分是是否为添加了 rule 的函数调用
static void mt_forwardInvocation(__unsafe_unretained id assignSlf, SEL selector, NSInvocation *invocation)
{
    MTDealloc *mtDealloc = nil;
    if (!mt_object_isClass(invocation.target)) {
        // 实例函数调用
        mtDealloc = objc_getAssociatedObject(invocation.target, invocation.selector);
    }
    else {
        // 类对象， 为什么要从元类中获取关联对象？？？
        mtDealloc = objc_getAssociatedObject(object_getClass(invocation.target), invocation.selector);
    }
    
    BOOL respondsToAlias = YES;
    // 这里获取类对象、元类对象的原因： instancesRespondToSelector只能获取实例方法，所以当 target 时 class 时，需要从原来对象中获取
    Class cls = object_getClass(invocation.target);
    
    // 整个逻辑是在匹配当前的 invocation 转发消息是否为 rule 注册的消息
    do {
        
        // 如果不存在 dealloc 对象，则通过target(实例)的类对象、target(类)的元类对象获取
        if (!mtDealloc.rule) {
            mtDealloc = objc_getAssociatedObject(cls, invocation.selector);
        }
        // 类对象、元类对象是否实现了保存 target method 的aliasSelector
        // instancesRespondToSelector会自动查找父类，这里为什么要用 do{}while 做呢， 猜测while的目的是获取mtDealloc， 因为 rule 是有继承关系的
        if ((respondsToAlias = [cls instancesRespondToSelector:mtDealloc.rule.aliasSelector])) {
            break;
        }
        mtDealloc = nil;
    }
    // 遍历继承链查找祖先类
    while (!respondsToAlias && (cls = class_getSuperclass(cls)));
    
    [mtDealloc lock];
    
    if (!respondsToAlias) {
        // 该invocation消息非 hook 的函数， 执行原类的ForwardInvocation消息转发流程
        mt_executeOrigForwardInvocation(assignSlf, selector, invocation);
    }
    else {
        // 执行 hook 逻辑
        mt_handleInvocation(invocation, mtDealloc.rule);
    }
    
    [mtDealloc unlock];
}

static NSString *const MTForwardInvocationSelectorName = @"__mt_forwardInvocation:";
static NSString *const MTSubclassPrefix = @"_MessageThrottle_";

/**
 获取实例对象的类。如果 instance 是类对象，则返回元类。
 兼容 KVO 用子类替换 isa 并覆写 class 方法的场景。
 */
static Class mt_classOfTarget(id target)
{
    Class cls;
    if (mt_object_isClass(target)) {
        cls = object_getClass(target);
    }
    else {
        cls = [target class];
    }
    return cls;
}

// 仿 KVO 实现， 重写 class 实例方法，返回 hook 之前的类对象，
static void mt_hookedGetClass(Class class, Class statedClass)
{
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
    // 获取新的创建的class 的 class 实例方法
    Method method = class_getInstanceMethod(class, @selector(class));
    
    // 返回原来的类对象
    IMP newIMP = imp_implementationWithBlock(^(id self) {
        return statedClass;
    });
    
    // 交换
    class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

// 判断传入的函数 imp 是否为消息转发的 _objc_msgForward 函数
static BOOL mt_isMsgForwardIMP(IMP impl)
{
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

// 获取 _objc_msgForward 的 imp
static IMP mt_getMsgForwardIMP(Class cls, SEL selector)
{
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    Method originMethod = class_getInstanceMethod(cls, selector);
    const char *originType = (char *)method_getTypeEncoding(originMethod);
    if (originType != NULL && originType[0] == _C_STRUCT_B) {
        //In some cases that returns struct, we should use the '_stret' API:
        //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
        // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
        // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
        // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
        // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
        //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:originType];
        if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
            msgForwardIMP = (IMP)_objc_msgForward_stret;
        }
    }
#endif
    return msgForwardIMP;
}

// 通过 isa swizzing 实现 实例的 hook
static BOOL mt_overrideMethod(MTRule *rule)
{   // 根据第四篇文章解析，是为了兼容 KVO 的 isa hook,
    id target = rule.target;
    SEL selector = rule.selector;
    
    // 保留被 hook 的函数 imp 指针
    SEL aliasSelector = rule.aliasSelector;
    
    Class cls;
    // KVO 会覆写 class 返回实例原来指向的类
    Class statedClass = [target class];
    
    // 但是 object_getClass 始终指向实例的真实的类
    Class baseClass = object_getClass(target);
    NSString *className = NSStringFromClass(baseClass);
    
    if ([className hasPrefix:MTSubclassPrefix]) {
        // 该类已经进行过 本库的 hook, MessageThrottle hook 会添加 MTSubclassPrefix 前缀
        cls = baseClass;
    }
    else if (mt_object_isClass(target)) {
        // 类对象不进行 hook
        cls = target;
    }
    else if (statedClass != baseClass) {
        // 两个类不等表明被其他 hook 过
        cls = baseClass;
    }
    else {
        // 拼接 动态创建的类，_MessageThrottle_xxxx
        const char *subclassName = [MTSubclassPrefix stringByAppendingString:className].UTF8String;
        
        // 由名字获取类
        Class subclass = objc_getClass(subclassName);
        
        if (subclass == nil) {
            // 不存在则走动态创建，
            subclass = objc_allocateClassPair(baseClass, subclassName, 0);
            if (subclass == nil) {
                NSLog(@"objc_allocateClassPair failed to allocate class %s.", subclassName);
                return NO;
            }
            // 为什么要 hook 实例方法以及类方法，因为 class 函数， 实例方法返回实例的类对象， 类方法返回自身
            // swizzing class 实例方法返回原来的类对象
            mt_hookedGetClass(subclass, statedClass);
            
            // swizzing class 类方法， 指向原来的statedClass, hook 类方法完全可以使用 class_getClassMethod, 这里可能是为了统一函数调用，所以传入的类对象的元类对象
            // 最终为 instance => _MessageThrottle_xxxx => statedClass
            mt_hookedGetClass(object_getClass(subclass), statedClass);
            objc_registerClassPair(subclass);
        }
        
        // 设置 target 的 isa 指向新的 hook 的类对象
        object_setClass(target, subclass);
        cls = subclass;
    }
    
    // check if subclass has hooked!
    
    // 遍历所有已经 hook 过的 class 类，是否有正在 hook 的类或者其子类
    for (Class clsHooked in MTEngine.defaultEngine.classHooked) {
        if (clsHooked != cls && [clsHooked isSubclassOfClass:cls]) {
            NSLog(@"Sorry: %@ used to be applied, can't apply it's super class %@!", NSStringFromClass(cls), NSStringFromClass(cls));
            return NO;
        }
    }
    
    [rule mt_deallocObject].cls = cls;
    
    // 判断当前类的 forwardInvocation：是否为已经 hook 过的 mt_forwardInvocation函数
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != (IMP)mt_forwardInvocation)
    {
        // 交换
        IMP originalImplementation = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)mt_forwardInvocation, "v@:@");
        // 将原来的forwardInvocation指向 MTForwardInvocationSelectorName ，以防影响其他业务中消息转发流程
        if (originalImplementation) {
            class_addMethod(cls, NSSelectorFromString(MTForwardInvocationSelectorName), originalImplementation, "v@:@");
        }
    }
    
    Class superCls = class_getSuperclass(cls);
    Method targetMethod = class_getInstanceMethod(cls, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    
    // 如果 hook 的函数不_objc_msgForward, 则将所有的 imp 都指向 _objc_msgForward，该函数会最终转发到forwardInvocation，由于已经 hook forwardInvocation,所以会转发到自定义的 mt_forwardInvocation。
    if (!mt_isMsgForwardIMP(targetMethodIMP)) {
        // 获取需要 hook 的函数的签名信息
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        Method targetAliasMethod = class_getInstanceMethod(cls, aliasSelector);
        Method targetAliasMethodSuper = class_getInstanceMethod(superCls, aliasSelector);
        // 判断 hook 的类中是否实现类指定的aliasSelector实例方法 || targetAliasMethod == targetAliasMethodSuper相等时代表子类没有重写，该aliasSelector 方法是父类实现的，对应解决是文章四中提到的：Revert Hook 的缺陷第一种场景，
        if (![cls instancesRespondToSelector:aliasSelector] || targetAliasMethod == targetAliasMethodSuper) {
            // 添加aliasSelector方法到 hook 的类对象中，实现为target 中需要做节流防抖处理的函数
            __unused BOOL addedAlias = class_addMethod(cls, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), cls);
        }
        
        // 将 target method 的 imp 指向 _objc_msgForward
        class_replaceMethod(cls, selector, mt_getMsgForwardIMP(statedClass, selector), typeEncoding);
        
        // 将 hook 的类对象记录到 MTEngine 单例中
        [MTEngine.defaultEngine.classHooked addObject:cls];
    }
    
    return YES;
}

static void mt_revertHook(Class cls, SEL selector, SEL aliasSelector)
{
    Method targetMethod = class_getInstanceMethod(cls, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (mt_isMsgForwardIMP(targetMethodIMP)) {
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        Method originalMethod = class_getInstanceMethod(cls, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), cls);
        class_replaceMethod(cls, selector, originalIMP, typeEncoding);
    }
    
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) == (IMP)mt_forwardInvocation) {
        Method originalMethod = class_getInstanceMethod(cls, NSSelectorFromString(MTForwardInvocationSelectorName));
        Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
        IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
        class_replaceMethod(cls, @selector(forwardInvocation:), originalImplementation, "v@:@");
    }
}

// 恢复函数交换
static BOOL mt_recoverMethod(id target, SEL selector, SEL aliasSelector)
{
    Class cls;
    if (mt_object_isClass(target)) {
        cls = target;
        if ([MTEngine.defaultEngine containsSelector:selector onTargetsOfClass:cls]) {
            return NO;
        }
    }
    else {
        MTDealloc *mtDealloc = objc_getAssociatedObject(target, selector);
        // get class when apply rule on target.
        cls = mtDealloc.cls;
        // target current real class name
        NSString *className = NSStringFromClass(object_getClass(target));
        if ([className hasPrefix:MTSubclassPrefix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:MTSubclassPrefix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            if (originalClass) {
                object_setClass(target, originalClass);
            }
        }
        if ([MTEngine.defaultEngine containsSelector:selector onTarget:cls] ||
            [MTEngine.defaultEngine containsSelector:selector onTargetsOfClass:cls]) {
            return NO;
        }
    }
    mt_revertHook(cls, selector, aliasSelector);
    return YES;
}

// 执行默认的 forwarded 函数
static void mt_executeOrigForwardInvocation(id slf, SEL selector, NSInvocation *invocation)
{
    // 保存的原来的消息转发函数实现
    SEL origForwardSelector = NSSelectorFromString(MTForwardInvocationSelectorName);
    if ([object_getClass(slf) instancesRespondToSelector:origForwardSelector]) {
        // 如果当前 target 的类对象实现了 forward 消息转发实例函数，则直接调用，否则
        NSMethodSignature *methodSignature = [slf methodSignatureForSelector:origForwardSelector];
        if (!methodSignature) {
            NSCAssert(NO, @"unrecognized selector -%@ for instance %@", NSStringFromSelector(origForwardSelector), slf);
            return;
        }
        NSInvocation *forwardInv= [NSInvocation invocationWithMethodSignature:methodSignature];
        [forwardInv setTarget:slf];
        [forwardInv setSelector:origForwardSelector];
        [forwardInv setArgument:&invocation atIndex:2];
        [forwardInv invoke];
    } else {
        // 查找父类的forwardInvocation 调用
        Class superCls = [[slf class] superclass];
        Method superForwardMethod = class_getInstanceMethod(superCls, @selector(forwardInvocation:));
        void (*superForwardIMP)(id, SEL, NSInvocation *);
        superForwardIMP = (void (*)(id, SEL, NSInvocation *))method_getImplementation(superForwardMethod);
        superForwardIMP(slf, @selector(forwardInvocation:), invocation);
    }
}

@end

@implementation NSObject (MessageThrottle)

// 获取所有应用的规则
- (NSArray<MTRule *> *)mt_allRules
{
    // 通过遍历单例维护的所有规则
    NSMutableArray<MTRule *> *result = [NSMutableArray array];
    for (MTRule *rule in MTEngine.defaultEngine.allRules) {
        if (rule.target == self || rule.target == mt_classOfTarget(self)) {
            [result addObject:rule];
        }
    }
    return [result copy];
}

- (nullable MTRule *)mt_limitSelector:(SEL)selector oncePerDuration:(NSTimeInterval)durationThreshold
{
    return [self mt_limitSelector:selector oncePerDuration:durationThreshold usingMode:MTPerformModeDebounce];
}

- (nullable MTRule *)mt_limitSelector:(SEL)selector oncePerDuration:(NSTimeInterval)durationThreshold usingMode:(MTPerformMode)mode
{
    return [self mt_limitSelector:selector oncePerDuration:durationThreshold usingMode:mode onMessageQueue:dispatch_get_main_queue()];
}

- (nullable MTRule *)mt_limitSelector:(SEL)selector oncePerDuration:(NSTimeInterval)durationThreshold usingMode:(MTPerformMode)mode onMessageQueue:(dispatch_queue_t)messageQueue
{
    return [self mt_limitSelector:selector oncePerDuration:durationThreshold usingMode:mode onMessageQueue:messageQueue alwaysInvokeBlock:nil];
}

// 实际工厂类，self 表示需要绑定的元类/类/实例
- (nullable MTRule *)mt_limitSelector:(SEL)selector oncePerDuration:(NSTimeInterval)durationThreshold usingMode:(MTPerformMode)mode onMessageQueue:(dispatch_queue_t)messageQueue alwaysInvokeBlock:(id)alwaysInvokeBlock
{
    MTDealloc *mtDealloc = objc_getAssociatedObject(self, selector);
    
    // 获取MTDealloc关联的 rule
    MTRule *rule = mtDealloc.rule;
    BOOL isNewRule = NO;
    if (!rule) {
        // 如果不存在 rule 对象，则新建一个
        rule = [[MTRule alloc] initWithTarget:self selector:selector durationThreshold:durationThreshold];
        isNewRule = YES;
    }
    
    rule.durationThreshold = durationThreshold;
    rule.mode = mode;
    rule.messageQueue = messageQueue ?: dispatch_get_main_queue();
    rule.alwaysInvokeBlock = alwaysInvokeBlock;
    // 是否是MTPerformModeFirstly规则，并且间隔时长 > 5, 设置持久化
    rule.persistent = (mode == MTPerformModeFirstly && durationThreshold > 5 && mt_object_isClass(self));
    if (isNewRule) {
        // 如果是首次创建的，则调用 apple 应用
        return [rule apply] ? rule : nil;
    }
    
    return rule;
}

@end
