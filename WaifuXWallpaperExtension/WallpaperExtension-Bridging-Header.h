//
//  WallpaperExtension-Bridging-Header.h
//  WaifuXWallpaperExtension
//
//  ObjC protocol definitions matching WallpaperExtensionKit.
//  XPC type classes are loaded at runtime via dlopen.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// MARK: - Private CAContext API (for remote rendering)

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
+ (id)contextWithCGSConnection:(unsigned int)cgsconnection options:(id)options;
+ (void)setAllowsCGSConnections:(_Bool)cgsconnections;
@end

// MARK: - Private CGS API

extern unsigned int CGSMainConnectionID(void);

// MARK: - Extension -> Host protocol (what we can call on WallpaperAgent)

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (^ _Nonnull)(id _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

// MARK: - Host -> Extension protocol (what WallpaperAgent calls on us)

@protocol WallpaperExtensionXPCProtocol <NSObject>
// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Downloads
// WallpaperExtensionKit's wire reply boxes this value (unlike canSkipShuffledContent).
// A scalar BOOL makes NSXPC reject the request before the handler can run.
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSNumber * _Nonnull, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end
