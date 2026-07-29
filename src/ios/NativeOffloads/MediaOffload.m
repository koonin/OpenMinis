//
//  MediaOffload.m
//  MinisApp
//
//  Native offload handler for `apple-media`.
//  Subcommands: now-playing, play, pause, toggle, next, prev, volume,
//               search, catalog-search, play-search, play-playlist, play-store-id
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <StoreKit/StoreKit.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#elif __has_include("MinisApp-Swift.h")
#import "MinisApp-Swift.h"
#else
@interface AudioSessionOffloadBridge : NSObject
+ (NSString *_Nullable)beginApplicationMusic;
+ (void)endApplicationMusic;
@end
#endif

static NSString *const TOOL_NAME = @"apple-media";
static NSString *const SYSTEM_MUSIC_WILL_PLAY_NOTIFICATION =
    @"OpenMinis.SystemMusicWillPlay";
static NSString *const SYSTEM_MUSIC_QUEUE_OWNER_DEFAULTS_KEY =
    @"OpenMinis.AppleMedia.SystemMusicOwnsCurrentQueue";
static NSString *const SYSTEM_MUSIC_CONTEXT_DEFAULTS_KEY =
    @"OpenMinis.AppleMedia.LastSystemMusicContext";
static NSString *const SYSTEM_MUSIC_REQUESTED_STATE_DEFAULTS_KEY =
    @"OpenMinis.AppleMedia.LastSystemMusicRequestedState";
static const NSTimeInterval MEDIA_AUTH_TIMEOUT_SECONDS = 15.0;
static const NSTimeInterval MEDIA_QUERY_TIMEOUT_SECONDS = 10.0;
static const NSTimeInterval CLOUD_CAPABILITY_TIMEOUT_SECONDS = 15.0;
static const NSTimeInterval MEDIA_PLAYBACK_TIMEOUT_SECONDS = 20.0;
static const NSTimeInterval MEDIA_TRANSPORT_TIMEOUT_SECONDS = 5.0;

static NSString *const HELP_TEXT =
    @"apple-media - Control iOS music playback and search the media library\n"
     "\n"
     "USAGE:\n"
     "  apple-media [command] [options]\n"
     "\n"
     "COMMANDS:\n"
     "  now-playing  Get currently playing track info (default when no command given)\n"
     "  play         Resume playback\n"
     "  pause        Pause playback\n"
     "  toggle       Toggle play/pause\n"
     "  next         Skip to next track\n"
     "  prev         Skip to previous track\n"
     "  volume       Get or set system volume\n"
     "  search       Search the media library\n"
     "  catalog-search Search the public iTunes music catalog\n"
     "  play-search  Search the library and play the first exact item\n"
     "  play-playlist Play a named library playlist\n"
     "  play-store-id Play an Apple Music/iTunes store identifier\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "\n"
     "VOLUME OPTIONS:\n"
     "  --set <0.0-1.0>      Set volume level\n"
     "\n"
     "SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --type <type>        song, album, artist, playlist (default: song)\n"
     "  --limit <N>          Maximum results (default: 100)\n"
     "\n"
     "PLAY-SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --type <type>        song, album, artist (default: song)\n"
     "  --artist <text>      Optional artist filter for song searches\n"
     "\n"
     "PLAYLIST OPTIONS:\n"
     "  --query <text>       Playlist name (required)\n"
     "\n"
     "STORE/CATALOG OPTIONS:\n"
     "  --id <store-id>      Store identifier to play (required)\n"
     "  --query <text>       Catalog search text (required)\n"
     "  --country <CC>       Two-letter storefront country (default: device region)\n"
     "  --limit <N>          Catalog results, 1-25 (default: 10)\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-media                    (same as: apple-media now-playing)\n"
     "  apple-media play\n"
     "  apple-media toggle\n"
     "  apple-media volume --set 0.5\n"
     "  apple-media search --query \"Beatles\" --type artist\n"
     "  apple-media play-search --query \"Song Title\" --artist \"Artist Name\"\n"
     "  apple-media play-playlist --query \"Favorites\"\n"
     "  apple-media catalog-search --query \"Artist Song\" --country US\n"
     "  apple-media play-store-id --id <store-id>\n";

// Serial queue to prevent concurrent authorization dialogs
static dispatch_queue_t authQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.openminis.media.auth", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Request media library authorization synchronously from the guest worker.
// Only the authorization presentation itself is dispatched to the main queue.
static BOOL requestMediaAccess(NSString **outError) {
    __block MPMediaLibraryAuthorizationStatus status =
        [MPMediaLibrary authorizationStatus];
    __block BOOL timedOut = NO;

    if (status == MPMediaLibraryAuthorizationStatusAuthorized) {
        return YES;
    }
    if (status == MPMediaLibraryAuthorizationStatusDenied ||
        status == MPMediaLibraryAuthorizationStatusRestricted) {
        if (outError) {
            *outError = @"Media library access not granted. "
                         "To grant access, open Settings > Privacy & Security > Media & Apple Music "
                         "and enable Minis.";
        }
        return NO;
    }
    if ([NSThread isMainThread]) {
        if (outError) {
            *outError = @"Media authorization must be requested from a background tool worker.";
        }
        return NO;
    }

    dispatch_sync(authQueue(), ^{
        status = [MPMediaLibrary authorizationStatus];
        if (status != MPMediaLibraryAuthorizationStatusNotDetermined) {
            return;
        }

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus s) {
                status = s;
                dispatch_semaphore_signal(sem);
            }];
        });
        long waitResult = dispatch_semaphore_wait(
            sem,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(MEDIA_AUTH_TIMEOUT_SECONDS * NSEC_PER_SEC)));
        timedOut = (waitResult != 0);
    });

    if (timedOut) {
        if (outError) {
            *outError = @"Timed out while waiting for Media & Apple Music permission.";
        }
        return NO;
    }
    if (status != MPMediaLibraryAuthorizationStatusAuthorized) {
        if (outError) {
            *outError = @"Media library access not granted. "
                         "To grant access, open Settings > Privacy & Security > Media & Apple Music "
                         "and enable Minis.";
        }
        return NO;
    }
    return YES;
}

// Resolve the user's Apple Music playback capability away from the main
// thread before a cloud-backed queue reaches MediaPlayer. Besides producing a
// useful subscription/account error, this warms iTunesCloud's user-identity
// store. On iOS 26, letting MPMusicPlayerController initialize that store for
// the first time while serializing a queue on the main thread can deadlock in
// ICUserIdentityStore until the watchdog kills the app.
static dispatch_queue_t cloudCapabilityQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create(
            "com.openminis.media.cloud-capability",
            DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static BOOL ensure_cloud_catalog_playback(NSString **outError) {
    if ([NSThread isMainThread]) {
        if (outError) {
            *outError = @"Apple Music cloud capability must be checked off the main thread.";
        }
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block SKCloudServiceCapability capabilities = SKCloudServiceCapabilityNone;
    __block NSError *capabilityError = nil;
    __block SKCloudServiceController *controller = nil;

    dispatch_async(cloudCapabilityQueue(), ^{
        controller = [[SKCloudServiceController alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [controller requestCapabilitiesWithCompletionHandler:
            ^(SKCloudServiceCapability result, NSError *error) {
                capabilities = result;
                capabilityError = error;
                controller = nil;
                dispatch_semaphore_signal(sem);
            }];
#pragma clang diagnostic pop
    });

    long waitResult = dispatch_semaphore_wait(
        sem,
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(CLOUD_CAPABILITY_TIMEOUT_SECONDS * NSEC_PER_SEC)));
    if (waitResult != 0) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Timed out after %.0f seconds while checking Apple Music account capability. "
                 "Open the Music app once, confirm the account/subscription, then retry.",
                CLOUD_CAPABILITY_TIMEOUT_SECONDS];
        }
        return NO;
    }
    if (capabilityError) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Unable to check Apple Music account capability: %@ (domain=%@, code=%ld)",
                capabilityError.localizedDescription ?: @"unknown error",
                capabilityError.domain ?: @"unknown",
                (long)capabilityError.code];
        }
        return NO;
    }
    if ((capabilities & SKCloudServiceCapabilityMusicCatalogPlayback) == 0) {
        if (outError) {
            *outError = @"This Apple Music account cannot stream catalog songs. "
                         "Confirm an active subscription and enable Sync Library in Settings.";
        }
        return NO;
    }
    return YES;
}

static BOOL media_items_require_cloud(NSArray<MPMediaItem *> *items) {
    for (MPMediaItem *item in items) {
        if ([[item valueForProperty:MPMediaItemPropertyIsCloudItem] boolValue]) {
            return YES;
        }
    }
    return NO;
}

// Returns nil unless every item can be represented by a catalog store ID.
// Passing only these strings to the system Music app avoids serializing the
// MPMediaItem/MPMediaQuery objects that trigger the iOS 26 iTunesCloud hang.
static NSArray<NSString *> *store_ids_for_all_items(
    NSArray<MPMediaItem *> *items
) {
    NSMutableArray<NSString *> *storeIDs =
        [NSMutableArray arrayWithCapacity:items.count];
    for (MPMediaItem *item in items) {
        NSString *storeID = item.playbackStoreID;
        if (storeID.length == 0) {
            return nil;
        }
        [storeIDs addObject:storeID];
    }
    return [storeIDs copy];
}

// Build a dict from an MPMediaItem
static NSDictionary *media_item_to_dict(MPMediaItem *item) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = item.title ?: [NSNull null];
    d[@"artist"] = item.artist ?: [NSNull null];
    d[@"album"] = item.albumTitle ?: [NSNull null];
    d[@"duration_seconds"] = @(item.playbackDuration);
    d[@"track_number"] = @(item.albumTrackNumber);
    d[@"genre"] = item.genre ?: [NSNull null];
    d[@"play_count"] = @(item.playCount);
    d[@"persistent_id"] =
        [NSString stringWithFormat:@"%llu", (unsigned long long)item.persistentID];
    d[@"store_id"] = item.playbackStoreID.length > 0
        ? item.playbackStoreID
        : (id)[NSNull null];
    d[@"is_cloud_item"] =
        [item valueForProperty:MPMediaItemPropertyIsCloudItem] ?: @NO;
    return d;
}

// Media library queries are synchronous and can occasionally wait on the
// cloud library daemon. Run them on a disposable worker so the guest command
// still has a bounded deadline if that daemon never replies.
static BOOL fetch_media_query_results(
    MPMediaQuery *query,
    BOOL collections,
    NSArray **outResults,
    NSString **outError
) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSArray *results = nil;
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                results = collections ? (query.collections ?: @[])
                                      : (query.items ?: @[]);
                dispatch_semaphore_signal(sem);
            }
        });
    long waitResult = dispatch_semaphore_wait(
        sem,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(MEDIA_QUERY_TIMEOUT_SECONDS * NSEC_PER_SEC)));
    if (waitResult != 0) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Timed out after %.0f seconds while reading the media library.",
                MEDIA_QUERY_TIMEOUT_SECONDS];
        }
        return NO;
    }
    if (outResults) *outResults = results;
    return YES;
}

static NSString *playback_state_string(MPMusicPlaybackState state) {
    switch (state) {
        case MPMusicPlaybackStatePlaying:          return @"playing";
        case MPMusicPlaybackStatePaused:           return @"paused";
        case MPMusicPlaybackStateStopped:          return @"stopped";
        case MPMusicPlaybackStateInterrupted:      return @"interrupted";
        case MPMusicPlaybackStateSeekingForward:   return @"seeking_forward";
        case MPMusicPlaybackStateSeekingBackward:  return @"seeking_backward";
        default:                                   return @"unknown";
    }
}

// Local/downloaded media can remain in an application-owned queue. Cloud
// catalog media takes a different path below: it is handed to the system Music
// app as store IDs, because applicationQueuePlayer's implicit preparation can
// synchronously wedge the main thread in iTunesCloud on iOS 26.
static MPMusicPlayerApplicationController *managed_music_player(void) {
    NSCAssert([NSThread isMainThread], @"Music player access must stay on main");
    static MPMusicPlayerApplicationController *player = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        player = [MPMusicPlayerController applicationQueuePlayer];
        [player beginGeneratingPlaybackNotifications];
    });
    return player;
}

static BOOL system_music_owns_current_queue(void) {
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:SYSTEM_MUSIC_QUEUE_OWNER_DEFAULTS_KEY];
}

static void set_system_music_owns_current_queue(BOOL ownsQueue) {
    NSCAssert([NSThread isMainThread], @"Music queue ownership must stay on main");
    [[NSUserDefaults standardUserDefaults]
        setBool:ownsQueue
         forKey:SYSTEM_MUSIC_QUEUE_OWNER_DEFAULTS_KEY];
}

static NSDictionary *system_music_last_context(void) {
    NSData *data = [[NSUserDefaults standardUserDefaults]
        dataForKey:SYSTEM_MUSIC_CONTEXT_DEFAULTS_KEY];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]]
        ? (NSDictionary *)object
        : nil;
}

static void set_system_music_last_context(NSDictionary *context) {
    if (!context) {
        [[NSUserDefaults standardUserDefaults]
            removeObjectForKey:SYSTEM_MUSIC_CONTEXT_DEFAULTS_KEY];
        return;
    }
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:context options:0 error:nil];
    if (data) {
        [[NSUserDefaults standardUserDefaults]
            setObject:data
               forKey:SYSTEM_MUSIC_CONTEXT_DEFAULTS_KEY];
    }
}

static NSString *system_music_last_requested_state(void) {
    return [[NSUserDefaults standardUserDefaults]
        stringForKey:SYSTEM_MUSIC_REQUESTED_STATE_DEFAULTS_KEY];
}

static void set_system_music_last_requested_state(NSString *state) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (state.length > 0) {
        [defaults setObject:state
                     forKey:SYSTEM_MUSIC_REQUESTED_STATE_DEFAULTS_KEY];
    } else {
        [defaults removeObjectForKey:
            SYSTEM_MUSIC_REQUESTED_STATE_DEFAULTS_KEY];
    }
}

static MPMusicPlayerController<MPSystemMusicPlayerController> *
managed_system_music_player(void) {
    NSCAssert([NSThread isMainThread], @"Music player access must stay on main");
    static MPMusicPlayerController<MPSystemMusicPlayerController> *player = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        player = [MPMusicPlayerController systemMusicPlayer];
        [player beginGeneratingPlaybackNotifications];
    });
    return player;
}

static MPMusicPlayerController *current_transport_player(void) {
    NSCAssert([NSThread isMainThread], @"Music player access must stay on main");
    return system_music_owns_current_queue()
        ? (MPMusicPlayerController *)managed_system_music_player()
        : (MPMusicPlayerController *)managed_music_player();
}

// MPMusicPlayerController must only be inspected on the main thread.
static NSDictionary *now_playing_dict_for_player(MPMusicPlayerController *player) {
    NSCAssert([NSThread isMainThread], @"Music player access must stay on main");
    MPMediaItem *item = player.nowPlayingItem;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (item) {
        [d addEntriesFromDictionary:media_item_to_dict(item)];
        d[@"playback_time"] = @(player.currentPlaybackTime);
        d[@"artwork_available"] = @(item.artwork != nil);
    } else {
        d[@"title"] = [NSNull null];
        d[@"artist"] = [NSNull null];
        d[@"album"] = [NSNull null];
        d[@"duration_seconds"] = [NSNull null];
        d[@"playback_time"] = [NSNull null];
        d[@"artwork_available"] = @NO;
        d[@"persistent_id"] = [NSNull null];
        d[@"store_id"] = [NSNull null];
        d[@"is_cloud_item"] = [NSNull null];
    }
    d[@"playback_state"] = playback_state_string(player.playbackState);
    return [d copy];
}

static NSError *media_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OpenMinisMediaPlayback"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Media playback failed."}];
}

static NSString *playback_error_message(NSError *error) {
    if (!error) return @"Media playback failed.";
    return [NSString stringWithFormat:@"%@ (domain=%@, code=%ld)",
            error.localizedDescription ?: @"Media playback failed.",
            error.domain ?: @"unknown",
            (long)error.code];
}

// Cloud catalog playback is handed to the system Music app rather than
// prepared inside OpenMinis. The handoff is deliberately scheduled after this
// function returns so the CLI can flush its JSON result before iOS backgrounds
// OpenMinis. MPSystemMusicPlayerController exposes no completion callback, so
// callers report "handoff_to_music", never an unverified "playing" state.
static BOOL schedule_system_music_handoff(
    NSArray<NSString *> *storeIDs,
    NSString **outError
) {
    if ([NSThread isMainThread]) {
        if (outError) {
            *outError = @"Music app handoff must be scheduled from a tool worker.";
        }
        return NO;
    }
    if (storeIDs.count == 0) {
        if (outError) {
            *outError = @"Music app handoff requires at least one store identifier.";
        }
        return NO;
    }
    if (!ensure_cloud_catalog_playback(outError)) {
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSObject *handoffLock = [[NSObject alloc] init];
    __block BOOL cancelled = NO;
    __block NSString *schedulingError = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (handoffLock) {
            if (cancelled) return;
        }
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            schedulingError =
                @"OpenMinis must be in the foreground to hand playback to Music.";
            dispatch_semaphore_signal(sem);
            return;
        }

        MPMusicPlayerStoreQueueDescriptor *descriptor =
            [[MPMusicPlayerStoreQueueDescriptor alloc] initWithStoreIDs:storeIDs];
        descriptor.startItemID = storeIDs.firstObject;
        MPMusicPlayerController<MPSystemMusicPlayerController> *player =
            managed_system_music_player();
        set_system_music_owns_current_queue(YES);
        set_system_music_last_requested_state(@"handoff_requested");

        [[NSNotificationCenter defaultCenter]
            postNotificationName:SYSTEM_MUSIC_WILL_PLAY_NOTIFICATION
                          object:nil];

        // Let the native offload return and the shell flush JSON before Music
        // takes the foreground. There is intentionally no prepare/play call in
        // OpenMinis on this cloud path.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                @try {
                    [player openToPlayQueueDescriptor:descriptor];
                } @catch (NSException *exception) {
                    NSLog(@"[AppleMedia] Music handoff raised %@: %@",
                          exception.name,
                          exception.reason ?: @"unknown reason");
                }
            });
        dispatch_semaphore_signal(sem);
    });

    long waitResult = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    if (waitResult != 0) {
        @synchronized (handoffLock) {
            cancelled = YES;
        }
        if (outError) {
            *outError = @"Timed out while scheduling the Music app handoff.";
        }
        return NO;
    }
    if (schedulingError) {
        if (outError) {
            *outError = schedulingError;
        }
        return NO;
    }
    return YES;
}

typedef void (^MediaQueueConfigurator)(MPMusicPlayerController *player);

// Queue configuration, play, and player inspection form one
// asynchronous main-thread state machine. The guest worker waits with a hard
// deadline; late callbacks observe `finished` and never start delayed playback.
static BOOL configure_and_play(
    MediaQueueConfigurator configureQueue,
    BOOL requiresCloudPlayback,
    NSDictionary **outNowPlaying,
    NSString **outError
) {
    if ([NSThread isMainThread]) {
        if (outError) {
            *outError = @"Media playback cannot synchronously wait on the main thread.";
        }
        return NO;
    }

    if (requiresCloudPlayback && !ensure_cloud_catalog_playback(outError)) {
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSObject *attemptLock = [[NSObject alloc] init];
    __block BOOL finished = NO;
    __block NSError *playbackError = nil;
    __block NSDictionary *snapshot = nil;
    __block NSString *stage = @"waiting-for-main-thread";
    __block id playbackStateObserver = nil;
    __block id nowPlayingObserver = nil;
    __block id queueObserver = nil;
    __block MPMusicPlayerController *observedPlayer = nil;

    void (^setStage)(NSString *) = ^(NSString *nextStage) {
        @synchronized (attemptLock) {
            if (!finished) {
                stage = [nextStage copy];
            }
        }
    };

    void (^removeObservers)(void) = ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        if (playbackStateObserver) {
            [center removeObserver:playbackStateObserver];
            playbackStateObserver = nil;
        }
        if (nowPlayingObserver) {
            [center removeObserver:nowPlayingObserver];
            nowPlayingObserver = nil;
        }
        if (queueObserver) {
            [center removeObserver:queueObserver];
            queueObserver = nil;
        }
    };

    void (^finish)(NSError *, NSDictionary *) =
        ^(NSError *error, NSDictionary *playerSnapshot) {
            BOOL shouldSignal = NO;
            @synchronized (attemptLock) {
                if (!finished) {
                    finished = YES;
                    playbackError = error;
                    snapshot = playerSnapshot;
                    shouldSignal = YES;
                }
            }
            if (shouldSignal) {
                if (!error && configureQueue) {
                    if ([NSThread isMainThread]) {
                        set_system_music_owns_current_queue(NO);
                        set_system_music_last_context(nil);
                        set_system_music_last_requested_state(nil);
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            set_system_music_owns_current_queue(NO);
                            set_system_music_last_context(nil);
                            set_system_music_last_requested_state(nil);
                        });
                    }
                }
                removeObservers();
                if (error) {
                    if ([NSThread isMainThread]) {
                        [AudioSessionOffloadBridge endApplicationMusic];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [AudioSessionOffloadBridge endApplicationMusic];
                        });
                    }
                }
                dispatch_semaphore_signal(sem);
            }
        };

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (attemptLock) {
            if (finished) return;
        }

        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            finish(
                media_error(
                    5,
                    @"Apple Music can only start while OpenMinis is in the foreground."),
                nil);
            return;
        }

        setStage(@"activating-app-audio-session");
        NSString *sessionError =
            [AudioSessionOffloadBridge beginApplicationMusic];
        if (sessionError.length > 0) {
            finish(media_error(6, sessionError), nil);
            return;
        }

        setStage(@"creating-application-queue-player");
        MPMusicPlayerController *player = managed_music_player();
        observedPlayer = player;

        __block void (^inspectState)(void) = nil;
        inspectState = ^{
            @synchronized (attemptLock) {
                if (finished) return;
            }

            setStage(@"reading-playback-state");
            MPMusicPlaybackState state = player.playbackState;
            if (state == MPMusicPlaybackStatePlaying) {
                setStage(@"reading-now-playing-item");
                finish(nil, now_playing_dict_for_player(player));
            } else if (state == MPMusicPlaybackStateInterrupted) {
                finish(
                    media_error(3, @"Apple Music playback was interrupted."),
                    now_playing_dict_for_player(player));
            } else {
                setStage(@"waiting-for-playback-notification");
            }
        };

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        playbackStateObserver = [center
            addObserverForName:MPMusicPlayerControllerPlaybackStateDidChangeNotification
                        object:player
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        inspectState();
                    }];
        nowPlayingObserver = [center
            addObserverForName:MPMusicPlayerControllerNowPlayingItemDidChangeNotification
                        object:player
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        inspectState();
                    }];
        queueObserver = [center
            addObserverForName:MPMusicPlayerControllerQueueDidChangeNotification
                        object:player
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        setStage(@"queue-changed-awaiting-playback");
                    }];

        setStage(@"configuring-plain-media-item-queue");
        @try {
            if (configureQueue) {
                configureQueue(player);
            }
        } @catch (NSException *exception) {
            finish(media_error(1, exception.reason ?: @"Unable to configure the music queue."),
                   nil);
            return;
        }

        @synchronized (attemptLock) {
            if (finished) return;
        }

        // Do not call prepareToPlay here. On iOS 26 the ostensibly
        // asynchronous method can block synchronously inside
        // MediaPlayer/iTunesCloud before returning, wedging the main thread
        // until the watchdog kills the app. MPMusicPlayerController must stay
        // on the main thread, so moving that call to a worker is not valid.
        // `play` performs the required preparation itself; confirm the actual
        // state from MediaPlayer notifications instead of polling an XPC-backed
        // property ten times per second.
        setStage(@"calling-player-play");
        @try {
            [player play];
        } @catch (NSException *exception) {
            finish(media_error(2, exception.reason ?: @"Unable to start Music playback."),
                   now_playing_dict_for_player(player));
            return;
        }

        setStage(@"waiting-for-playback-notification");
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                @synchronized (attemptLock) {
                    if (finished) return;
                }
                setStage(@"final-playback-state-check");
                MPMusicPlaybackState state = observedPlayer.playbackState;
                if (state == MPMusicPlaybackStatePlaying) {
                    finish(nil, now_playing_dict_for_player(observedPlayer));
                } else {
                    finish(
                        media_error(
                            4,
                            [NSString stringWithFormat:
                                @"The queued item did not enter the playing state (state=%@).",
                                playback_state_string(state)]),
                        now_playing_dict_for_player(observedPlayer));
                }
            });
    });

    long waitResult = dispatch_semaphore_wait(
        sem,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(MEDIA_PLAYBACK_TIMEOUT_SECONDS * NSEC_PER_SEC)));
    if (waitResult != 0) {
        NSString *timeoutStage = nil;
        @synchronized (attemptLock) {
            finished = YES;
            timeoutStage = [stage copy];
        }
        removeObservers();
        dispatch_async(dispatch_get_main_queue(), ^{
            [AudioSessionOffloadBridge endApplicationMusic];
        });
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Timed out after %.0f seconds while starting Apple Music playback "
                 "(stage=%@).",
                MEDIA_PLAYBACK_TIMEOUT_SECONDS,
                timeoutStage ?: @"unknown"];
        }
        return NO;
    }

    if (outNowPlaying) {
        *outNowPlaying = snapshot;
    }
    if (playbackError) {
        if (outError) {
            *outError = playback_error_message(playbackError);
        }
        return NO;
    }
    return YES;
}

// Build a now-playing info dict from the current player state without an
// unbounded dispatch_sync(main).
static NSDictionary *now_playing_dict(void) {
    if (system_music_owns_current_queue()) {
        NSDictionary *context = system_music_last_context();
        NSString *requestedState = system_music_last_requested_state();
        return @{
            @"player": @"system_music",
            @"playback_state": @"system_managed",
            @"last_requested_state": requestedState ?: [NSNull null],
            @"context": context ?: [NSNull null],
            @"live_metadata_available": @NO,
            @"message":
                @"Live system-player metadata is not queried because MediaPlayer "
                 "can block the app while resolving iTunesCloud identity. "
                 "Use Music or Control Center for authoritative live metadata.",
        };
    }

    if ([NSThread isMainThread]) {
        return now_playing_dict_for_player(managed_music_player());
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        result = now_playing_dict_for_player(managed_music_player());
        dispatch_semaphore_signal(sem);
    });
    long waitResult = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    if (waitResult != 0) {
        return @{
            @"playback_state": @"unknown",
            @"error": @"Timed out while reading Apple Music playback state.",
        };
    }
    return result;
}

typedef void (^MediaTransportAction)(MPMusicPlayerController *player);

// Transport commands can be requested by a guest shell that remains alive
// briefly after Music takes the foreground. Never dispatch_sync to a suspended
// app main queue: bound the wait and cancel an action that has not started yet.
static BOOL perform_current_transport_action(
    NSString *actionName,
    MediaTransportAction action,
    NSString **outError
) {
    if ([NSThread isMainThread]) {
        if ([UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive) {
            if (outError) {
                *outError = @"Bring OpenMinis to the foreground before controlling Apple Music.";
            }
            return NO;
        }
        @try {
            action(current_transport_player());
            return YES;
        } @catch (NSException *exception) {
            if (outError) {
                *outError = exception.reason ?: @"The music transport command failed.";
            }
            return NO;
        }
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSObject *actionLock = [[NSObject alloc] init];
    __block BOOL cancelled = NO;
    __block NSString *actionError = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (actionLock) {
            if (cancelled) return;
        }
        if ([UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive) {
            actionError =
                @"Bring OpenMinis to the foreground before controlling Apple Music.";
            dispatch_semaphore_signal(sem);
            return;
        }
        @try {
            action(current_transport_player());
        } @catch (NSException *exception) {
            actionError =
                exception.reason ?: @"The music transport command failed.";
        }
        dispatch_semaphore_signal(sem);
    });

    long waitResult = dispatch_semaphore_wait(
        sem,
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(MEDIA_TRANSPORT_TIMEOUT_SECONDS * NSEC_PER_SEC)));
    if (waitResult != 0) {
        @synchronized (actionLock) {
            cancelled = YES;
        }
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Timed out after %.0f seconds while %@. "
                 "Keep OpenMinis in the foreground and try again.",
                MEDIA_TRANSPORT_TIMEOUT_SECONDS,
                actionName ?: @"controlling Apple Music"];
        }
        return NO;
    }
    if (actionError) {
        if (outError) {
            *outError = actionError;
        }
        return NO;
    }
    return YES;
}

static int cmd_now_playing(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = now_playing_dict();
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"now-playing", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    BOOL resumeSystemQueue = system_music_owns_current_queue();
    if (resumeSystemQueue) {
        NSString *actionError = nil;
        BOOL requested = perform_current_transport_action(
            @"resuming Apple Music",
            ^(MPMusicPlayerController *player) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:SYSTEM_MUSIC_WILL_PLAY_NOTIFICATION
                                  object:nil];
                [player play];
            },
            &actionError);
        if (!requested) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play",
                [actionError containsString:@"Timed out"]
                    ? NOFF_ERR_TIMEOUT
                    : NOFF_ERR_INTERNAL_ERROR,
                actionError);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        set_system_music_last_requested_state(@"playing_requested");
        NSDictionary *data = @{
            @"status": @"resume_requested",
            @"player": @"system_music",
            @"context": system_music_last_context() ?: [NSNull null],
        };
        noff_emit_json(
            stdout_fd,
            noff_json_envelope(TOOL_NAME, @"play", data),
            compact,
            quiet);
        return NOFF_EXIT_SUCCESS;
    }

    NSDictionary *nowPlaying = nil;
    NSString *playError = nil;
    if (!configure_and_play(nil, NO, &nowPlaying, &playError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play",
            [playError containsString:@"Timed out"] ? NOFF_ERR_TIMEOUT : NOFF_ERR_INTERNAL_ERROR,
            playError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    NSDictionary *data = @{
        @"status": @"playing",
        @"now_playing": nowPlaying ?: [NSNull null],
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_pause(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *actionError = nil;
    BOOL paused = perform_current_transport_action(
        @"pausing Apple Music",
        ^(MPMusicPlayerController *player) {
            [player pause];
            [AudioSessionOffloadBridge endApplicationMusic];
        },
        &actionError);
    if (!paused) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"pause",
            [actionError containsString:@"Timed out"]
                ? NOFF_ERR_TIMEOUT
                : NOFF_ERR_INTERNAL_ERROR,
            actionError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    BOOL systemRoute = system_music_owns_current_queue();
    if (systemRoute) {
        set_system_music_last_requested_state(@"paused_requested");
    }
    NSDictionary *data = @{
        @"status": systemRoute ? @"pause_requested" : @"paused",
        @"player": systemRoute ? @"system_music" : @"application_queue",
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"pause", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_toggle(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    if (system_music_owns_current_queue()) {
        if ([system_music_last_requested_state()
                isEqualToString:@"paused_requested"]) {
            return cmd_play(argc, argv, stdout_fd, compact, quiet);
        }
        return cmd_pause(argc, argv, stdout_fd, compact, quiet);
    }
    NSDictionary *snapshot = now_playing_dict();
    if ([snapshot[@"playback_state"] isEqualToString:@"playing"]) {
        return cmd_pause(argc, argv, stdout_fd, compact, quiet);
    }
    return cmd_play(argc, argv, stdout_fd, compact, quiet);
}

static int cmd_next(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *actionError = nil;
    if (!perform_current_transport_action(
            @"skipping to the next Apple Music item",
            ^(MPMusicPlayerController *player) {
                [player skipToNextItem];
            },
            &actionError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"next",
            [actionError containsString:@"Timed out"]
                ? NOFF_ERR_TIMEOUT
                : NOFF_ERR_INTERNAL_ERROR,
            actionError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    // Brief wait for track to change
    usleep(300000);

    NSDictionary *snapshot = now_playing_dict();
    NSDictionary *np = nil;
    if (snapshot[@"title"] && snapshot[@"title"] != [NSNull null]) {
        np = @{
            @"title": snapshot[@"title"],
            @"artist": snapshot[@"artist"] ?: [NSNull null],
            @"album": snapshot[@"album"] ?: [NSNull null],
        };
    }

    id nowPlayingPayload = system_music_owns_current_queue()
        ? (id)snapshot
        : (id)(np ?: [NSNull null]);
    NSDictionary *data = @{
        @"status": @"next",
        @"now_playing": nowPlayingPayload,
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"next", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_prev(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *actionError = nil;
    if (!perform_current_transport_action(
            @"skipping to the previous Apple Music item",
            ^(MPMusicPlayerController *player) {
                [player skipToPreviousItem];
            },
            &actionError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"prev",
            [actionError containsString:@"Timed out"]
                ? NOFF_ERR_TIMEOUT
                : NOFF_ERR_INTERNAL_ERROR,
            actionError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    // Brief wait for track to change
    usleep(300000);

    NSDictionary *snapshot = now_playing_dict();
    NSDictionary *np = nil;
    if (snapshot[@"title"] && snapshot[@"title"] != [NSNull null]) {
        np = @{
            @"title": snapshot[@"title"],
            @"artist": snapshot[@"artist"] ?: [NSNull null],
            @"album": snapshot[@"album"] ?: [NSNull null],
        };
    }

    id nowPlayingPayload = system_music_owns_current_queue()
        ? (id)snapshot
        : (id)(np ?: [NSNull null]);
    NSDictionary *data = @{
        @"status": @"previous",
        @"now_playing": nowPlayingPayload,
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"prev", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_volume(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *setStr = noff_find_arg(argc, argv, "--set");

    if (setStr) {
        float newVolume = [setStr floatValue];
        if (newVolume < 0.0f) newVolume = 0.0f;
        if (newVolume > 1.0f) newVolume = 1.0f;

        noff_dispatch_main_sync(^id{
            MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
            UISlider *volumeSlider = nil;
            for (UIView *view in volumeView.subviews) {
                if ([view isKindOfClass:[UISlider class]]) {
                    volumeSlider = (UISlider *)view;
                    break;
                }
            }
            if (volumeSlider) {
                volumeSlider.value = newVolume;
                [volumeSlider sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
            return nil;
        });
        // Brief wait for volume change to take effect
        usleep(100000);
    }

    float currentVolume = [[AVAudioSession sharedInstance] outputVolume];

    NSDictionary *data = @{@"volume": @(currentVolume)};
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"volume", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (query.length == 0) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"song";
    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitStr ? [limitStr integerValue] : 100;
    if (limit <= 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--limit must be greater than zero");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    MPMediaQuery *mediaQuery = nil;
    MPMediaPropertyPredicate *predicate = nil;

    if ([type isEqualToString:@"song"]) {
        mediaQuery = [MPMediaQuery songsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyTitle
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else if ([type isEqualToString:@"album"]) {
        mediaQuery = [MPMediaQuery albumsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyAlbumTitle
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else if ([type isEqualToString:@"artist"]) {
        mediaQuery = [MPMediaQuery artistsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyArtist
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else if ([type isEqualToString:@"playlist"]) {
        mediaQuery = [MPMediaQuery playlistsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaPlaylistPropertyName
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--type must be song, album, artist, or playlist");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    if (!requestMediaAccess(&authErr)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"search",
            [authErr containsString:@"Timed out"] ? NOFF_ERR_TIMEOUT : NOFF_ERR_AUTHORIZATION_DENIED,
            authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return [authErr containsString:@"Timed out"] ? NOFF_EXIT_ERROR : NOFF_EXIT_AUTH_DENIED;
    }

    [mediaQuery addFilterPredicate:predicate];

    NSArray *rawItems = nil;
    NSString *queryError = nil;
    if (!fetch_media_query_results(
            mediaQuery, NO, &rawItems, &queryError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"search", NOFF_ERR_TIMEOUT, queryError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    NSArray<MPMediaItem *> *items = (NSArray<MPMediaItem *> *)rawItems;
    NSInteger totalCount = (NSInteger)items.count;
    if (totalCount > limit) {
        items = [items subarrayWithRange:NSMakeRange(0, limit)];
    }

    NSMutableArray *results = [NSMutableArray array];
    for (MPMediaItem *item in items) {
        [results addObject:media_item_to_dict(item)];
    }

    NSMutableDictionary *data = [@{
        @"results": results,
        @"query": query,
        @"type": type,
        @"count": @(results.count),
    } mutableCopy];
    if (totalCount > limit) {
        data[@"_warning"] = [NSString stringWithFormat:
            @"Results truncated by --limit. Returned %ld of %ld total records. "
             "Use a larger --limit to retrieve more data.",
            (long)limit, (long)totalCount];
        data[@"total_available"] = @(totalCount);
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"search", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (query.length == 0) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"song";
    NSString *artist = noff_find_arg(argc, argv, "--artist");

    MPMediaQuery *mediaQuery = nil;
    MPMediaPropertyPredicate *predicate = nil;

    if ([type isEqualToString:@"song"]) {
        mediaQuery = [MPMediaQuery songsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyTitle
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else if ([type isEqualToString:@"album"]) {
        mediaQuery = [MPMediaQuery albumsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyAlbumTitle
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else if ([type isEqualToString:@"artist"]) {
        mediaQuery = [MPMediaQuery artistsQuery];
        predicate = [MPMediaPropertyPredicate predicateWithValue:query
                                                    forProperty:MPMediaItemPropertyArtist
                                                 comparisonType:MPMediaPredicateComparisonContains];
    } else {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--type must be song, album, or artist");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    [mediaQuery addFilterPredicate:predicate];
    if (artist.length > 0) {
        if (![type isEqualToString:@"song"]) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play-search", NOFF_ERR_INVALID_ARGS,
                @"--artist can only be used with --type song");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        [mediaQuery addFilterPredicate:
            [MPMediaPropertyPredicate
                predicateWithValue:artist
                       forProperty:MPMediaItemPropertyArtist
                    comparisonType:MPMediaPredicateComparisonContains]];
    }

    NSString *authErr = nil;
    if (!requestMediaAccess(&authErr)) {
        BOOL authTimedOut = [authErr containsString:@"Timed out"];
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-search",
            authTimedOut ? NOFF_ERR_TIMEOUT : NOFF_ERR_AUTHORIZATION_DENIED,
            authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return authTimedOut ? NOFF_EXIT_ERROR : NOFF_EXIT_AUTH_DENIED;
    }

    NSArray *rawItems = nil;
    NSString *queryError = nil;
    if (!fetch_media_query_results(
            mediaQuery, NO, &rawItems, &queryError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-search", NOFF_ERR_TIMEOUT, queryError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    NSArray<MPMediaItem *> *items = (NSArray<MPMediaItem *> *)rawItems;
    if (!items || items.count == 0) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"play-search",
                                             NOFF_ERR_NO_DATA,
                                             [NSString stringWithFormat:@"No results for '%@'", query]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    MPMediaItem *selected = items.firstObject;
    for (MPMediaItem *candidate in items) {
        BOOL titleMatches =
            [candidate.title compare:query
                             options:(NSCaseInsensitiveSearch |
                                      NSDiacriticInsensitiveSearch)] == NSOrderedSame;
        BOOL artistMatches =
            artist.length == 0 ||
            [candidate.artist compare:artist
                              options:(NSCaseInsensitiveSearch |
                                       NSDiacriticInsensitiveSearch)] == NSOrderedSame;
        if (titleMatches && artistMatches) {
            selected = candidate;
            break;
        }
    }

    BOOL requiresCloud = media_items_require_cloud(@[selected]);
    if (requiresCloud) {
        NSString *storeID = selected.playbackStoreID;
        if (storeID.length == 0) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play-search", NOFF_ERR_NO_DATA,
                @"The cloud item has no playback store ID, so it cannot be handed safely to Music.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }

        NSString *handoffError = nil;
        if (!schedule_system_music_handoff(@[storeID], &handoffError)) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play-search",
                [handoffError containsString:@"Timed out"]
                    ? NOFF_ERR_TIMEOUT
                    : NOFF_ERR_INTERNAL_ERROR,
                handoffError);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }

        NSDictionary *matched = media_item_to_dict(selected);
        set_system_music_last_context(@{
            @"kind": @"track",
            @"matched": matched,
        });
        NSDictionary *data = @{
            @"status": @"handoff_to_music",
            @"player": @"system_music",
            @"matched": matched,
        };
        noff_emit_json(
            stdout_fd,
            noff_json_envelope(TOOL_NAME, @"play-search", data),
            compact,
            quiet);
        return NOFF_EXIT_SUCCESS;
    }

    MPMediaItemCollection *singleItem =
        [MPMediaItemCollection collectionWithItems:@[selected]];
    NSDictionary *nowPlaying = nil;
    NSString *playError = nil;
    BOOL played = configure_and_play(
        ^(MPMusicPlayerController *player) {
            [player setQueueWithItemCollection:singleItem];
        },
        NO,
        &nowPlaying,
        &playError);
    if (!played) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-search",
            [playError containsString:@"Timed out"] ? NOFF_ERR_TIMEOUT : NOFF_ERR_INTERNAL_ERROR,
            playError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"status": @"playing",
        @"matched": media_item_to_dict(selected),
        @"now_playing": nowPlaying ?: [NSNull null],
    };
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"play-search", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play_playlist(int argc, char **argv,
                             int stdout_fd, int stderr_fd,
                             BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (query.length == 0) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_INVALID_ARGS,
            @"Required: --query <playlist-name>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    if (!requestMediaAccess(&authErr)) {
        BOOL authTimedOut = [authErr containsString:@"Timed out"];
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist",
            authTimedOut ? NOFF_ERR_TIMEOUT : NOFF_ERR_AUTHORIZATION_DENIED,
            authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return authTimedOut ? NOFF_EXIT_ERROR : NOFF_EXIT_AUTH_DENIED;
    }

    MPMediaQuery *playlistQuery = [MPMediaQuery playlistsQuery];
    [playlistQuery addFilterPredicate:
        [MPMediaPropertyPredicate
            predicateWithValue:query
                   forProperty:MPMediaPlaylistPropertyName
                comparisonType:MPMediaPredicateComparisonContains]];

    NSMutableArray<MPMediaPlaylist *> *candidates = [NSMutableArray array];
    NSMutableArray<MPMediaPlaylist *> *exactMatches = [NSMutableArray array];
    NSArray *rawCollections = nil;
    NSString *queryError = nil;
    if (!fetch_media_query_results(
            playlistQuery, YES, &rawCollections, &queryError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_TIMEOUT, queryError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    NSArray<MPMediaItemCollection *> *playlistCollections =
        (NSArray<MPMediaItemCollection *> *)rawCollections;
    for (MPMediaItemCollection *collection in playlistCollections) {
        if (![collection isKindOfClass:[MPMediaPlaylist class]]) continue;
        MPMediaPlaylist *playlist = (MPMediaPlaylist *)collection;
        [candidates addObject:playlist];
        if ([playlist.name compare:query
                           options:(NSCaseInsensitiveSearch |
                                    NSDiacriticInsensitiveSearch)] == NSOrderedSame) {
            [exactMatches addObject:playlist];
        }
    }

    MPMediaPlaylist *selected = nil;
    if (exactMatches.count == 1) {
        selected = exactMatches.firstObject;
    } else if (exactMatches.count > 1) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:
                @"More than one playlist is named '%@'; rename one of them to make the choice unambiguous.",
                query]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    } else if (candidates.count == 1) {
        selected = candidates.firstObject;
    } else if (candidates.count > 1) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (MPMediaPlaylist *playlist in candidates) {
            NSString *name = playlist.name;
            [names addObject:name.length > 0 ? name : @"(unnamed playlist)"];
        }
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:
                @"Playlist name '%@' is ambiguous. Matches: %@",
                query, [names componentsJoinedByString:@", "]]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    if (!selected) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:@"No playlist found for '%@'.", query]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    if (selected.count == 0) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist", NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:@"Playlist '%@' is empty.", selected.name ?: query]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    // Never pass the MPMediaPlaylist subclass itself into MediaPlayer. On
    // iOS 26 it serializes its backing MPConcreteMediaPlaylist/MPMediaQuery
    // during play(), then synchronously waits for iTunesCloud account identity
    // on the main thread. A plain item collection preserves the same ordered
    // songs without carrying that query object into the playback descriptor.
    NSArray<MPMediaItem *> *playlistItems = [selected.items copy];
    MPMediaItemCollection *plainQueue =
        [MPMediaItemCollection collectionWithItems:playlistItems];
    BOOL requiresCloud = media_items_require_cloud(playlistItems);

    if (requiresCloud) {
        NSArray<NSString *> *storeIDs =
            store_ids_for_all_items(playlistItems);
        if (!storeIDs) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play-playlist", NOFF_ERR_NO_DATA,
                @"This cloud playlist contains an item without a playback store ID, "
                 "so it cannot be handed safely to Music.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }

        NSString *handoffError = nil;
        if (!schedule_system_music_handoff(storeIDs, &handoffError)) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"play-playlist",
                [handoffError containsString:@"Timed out"]
                    ? NOFF_ERR_TIMEOUT
                    : NOFF_ERR_INTERNAL_ERROR,
                handoffError);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }

        set_system_music_last_context(@{
            @"kind": @"playlist",
            @"playlist": selected.name ?: query,
            @"item_count": @(playlistItems.count),
            @"first_item": media_item_to_dict(playlistItems.firstObject),
        });
        NSDictionary *data = @{
            @"status": @"handoff_to_music",
            @"player": @"system_music",
            @"playlist": selected.name ?: query,
            @"item_count": @(playlistItems.count),
        };
        noff_emit_json(
            stdout_fd,
            noff_json_envelope(TOOL_NAME, @"play-playlist", data),
            compact,
            quiet);
        return NOFF_EXIT_SUCCESS;
    }

    NSDictionary *nowPlaying = nil;
    NSString *playError = nil;
    BOOL played = configure_and_play(
        ^(MPMusicPlayerController *player) {
            [player setQueueWithItemCollection:plainQueue];
        },
        NO,
        &nowPlaying,
        &playError);
    if (!played) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-playlist",
            [playError containsString:@"Timed out"] ? NOFF_ERR_TIMEOUT : NOFF_ERR_INTERNAL_ERROR,
            playError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"status": @"playing",
        @"playlist": selected.name ?: query,
        @"item_count": @(selected.count),
        @"now_playing": nowPlaying ?: [NSNull null],
    };
    noff_emit_json(
        stdout_fd,
        noff_json_envelope(TOOL_NAME, @"play-playlist", data),
        compact,
        quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_play_store_id(int argc, char **argv,
                             int stdout_fd, int stderr_fd,
                             BOOL compact, BOOL quiet) {
    NSString *storeID =
        [noff_find_arg(argc, argv, "--id")
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (storeID.length == 0 ||
        storeID.length > 128 ||
        [storeID rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-store-id", NOFF_ERR_INVALID_ARGS,
            @"Required: --id <non-whitespace Apple Music/iTunes store identifier>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *authErr = nil;
    if (!requestMediaAccess(&authErr)) {
        BOOL authTimedOut = [authErr containsString:@"Timed out"];
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-store-id",
            authTimedOut ? NOFF_ERR_TIMEOUT : NOFF_ERR_AUTHORIZATION_DENIED,
            authErr);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return authTimedOut ? NOFF_EXIT_ERROR : NOFF_EXIT_AUTH_DENIED;
    }

    NSString *handoffError = nil;
    if (!schedule_system_music_handoff(@[storeID], &handoffError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"play-store-id",
            [handoffError containsString:@"Timed out"]
                ? NOFF_ERR_TIMEOUT
                : NOFF_ERR_INTERNAL_ERROR,
            handoffError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    set_system_music_last_context(@{
        @"kind": @"store_id",
        @"store_id": storeID,
    });
    NSDictionary *data = @{
        @"status": @"handoff_to_music",
        @"player": @"system_music",
        @"store_id": storeID,
    };
    noff_emit_json(
        stdout_fd,
        noff_json_envelope(TOOL_NAME, @"play-store-id", data),
        compact,
        quiet);
    return NOFF_EXIT_SUCCESS;
}

static BOOL catalog_search(
    NSString *query,
    NSString *country,
    NSInteger limit,
    NSArray **outResults,
    NSString **outError
) {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"itunes.apple.com";
    components.path = @"/search";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:query],
        [NSURLQueryItem queryItemWithName:@"country" value:country],
        [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
        [NSURLQueryItem queryItemWithName:@"limit"
                                    value:[NSString stringWithFormat:@"%ld", (long)limit]],
    ];
    if (!components.URL) {
        if (outError) *outError = @"Unable to construct the iTunes catalog request.";
        return NO;
    }

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 12.0;
    configuration.timeoutIntervalForResource = 15.0;
    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSURLResponse *response = nil;
    __block NSError *requestError = nil;

    NSURLSessionDataTask *task =
        [session dataTaskWithURL:components.URL
              completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
        responseData = data;
        response = urlResponse;
        requestError = error;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    long waitResult = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        [session invalidateAndCancel];
        if (outError) *outError = @"Timed out while searching the iTunes catalog.";
        return NO;
    }
    [session finishTasksAndInvalidate];

    if (requestError) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"iTunes catalog request failed: %@",
                requestError.localizedDescription ?: @"unknown network error"];
        }
        return NO;
    }
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
        if (statusCode < 200 || statusCode >= 300) {
            if (outError) {
                *outError = [NSString stringWithFormat:
                    @"iTunes catalog returned HTTP %ld.", (long)statusCode];
            }
            return NO;
        }
    }

    NSError *jsonError = nil;
    NSDictionary *payload =
        [NSJSONSerialization JSONObjectWithData:responseData ?: [NSData data]
                                        options:0
                                          error:&jsonError];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"Unable to parse iTunes catalog response: %@",
                jsonError.localizedDescription ?: @"invalid JSON"];
        }
        return NO;
    }

    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *record in payload[@"results"] ?: @[]) {
        if (![record isKindOfClass:[NSDictionary class]]) continue;
        id rawTrackID = record[@"trackId"];
        NSString *storeID = nil;
        if ([rawTrackID isKindOfClass:[NSNumber class]]) {
            storeID = [(NSNumber *)rawTrackID stringValue];
        } else if ([rawTrackID isKindOfClass:[NSString class]]) {
            storeID = (NSString *)rawTrackID;
        }
        if (storeID.length == 0) continue;
        [results addObject:@{
            @"store_id": storeID,
            @"title": record[@"trackName"] ?: [NSNull null],
            @"artist": record[@"artistName"] ?: [NSNull null],
            @"album": record[@"collectionName"] ?: [NSNull null],
            @"duration_ms": record[@"trackTimeMillis"] ?: [NSNull null],
            @"is_streamable": record[@"isStreamable"] ?: [NSNull null],
            @"view_url": record[@"trackViewUrl"] ?: [NSNull null],
            @"artwork_url": record[@"artworkUrl100"] ?: [NSNull null],
        }];
    }
    if (outResults) *outResults = results;
    return YES;
}

static int cmd_catalog_search(int argc, char **argv,
                              int stdout_fd, int stderr_fd,
                              BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (query.length == 0) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"catalog-search", NOFF_ERR_INVALID_ARGS,
            @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *countryArgument = noff_find_arg(argc, argv, "--country");
    NSString *deviceCountry =
        [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    NSString *country =
        [(countryArgument ?: deviceCountry ?: @"CN") uppercaseString];
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    if (country.length != 2 ||
        [[country stringByTrimmingCharactersInSet:letters] length] != 0) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"catalog-search", NOFF_ERR_INVALID_ARGS,
            @"--country must be a two-letter country code, for example CN or US");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *limitValue = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitValue ? [limitValue integerValue] : 10;
    if (limit < 1 || limit > 25) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"catalog-search", NOFF_ERR_INVALID_ARGS,
            @"--limit must be between 1 and 25");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSArray *results = nil;
    NSString *searchError = nil;
    if (!catalog_search(query, country, limit, &results, &searchError)) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"catalog-search",
            [searchError containsString:@"Timed out"] ? NOFF_ERR_TIMEOUT : NOFF_ERR_INTERNAL_ERROR,
            searchError);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"query": query,
        @"country": country,
        @"count": @(results.count),
        @"results": results,
    };
    noff_emit_json(
        stdout_fd,
        noff_json_envelope(TOOL_NAME, @"catalog-search", data),
        compact,
        quiet);
    return NOFF_EXIT_SUCCESS;
}

static int media_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        // [T-offload-defaults-batch-ios] Bare `apple-media` (including
        // flags-only invocations) defaults to `now-playing` — a read-only
        // status query; never silently mutates playback.
        subcmd = @"now-playing";
    }

    if ([subcmd isEqualToString:@"now-playing"])  return cmd_now_playing(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play"])          return cmd_play(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"pause"])         return cmd_pause(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"toggle"])        return cmd_toggle(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"next"])          return cmd_next(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"prev"])          return cmd_prev(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"volume"])        return cmd_volume(argc, argv, stdout_fd, compact, quiet);
    if ([subcmd isEqualToString:@"search"])        return cmd_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"catalog-search"]) return cmd_catalog_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play-search"])   return cmd_play_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play-playlist"]) return cmd_play_playlist(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"play-store-id"]) return cmd_play_store_id(argc, argv, stdout_fd, stderr_fd, compact, quiet);

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: now-playing, play, pause, toggle, next, prev, volume, search, catalog-search, play-search, play-playlist, play-store-id. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void media_offload_register(void) {
    int err = native_offload_add_handler("apple-media", media_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-media");
        NSLog(@"NativeOffloads: apple-media handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-media handler (err=%d)", err);
    }
}
