// MediaBridge — a tiny Now Playing bridge for Bubble.
//
// Since macOS 15.4, MediaRemote only reports Now Playing info to Apple-signed processes.
// /usr/bin/perl is one, and it can load ordinary dylibs, so Bubble runs this library inside
// perl as a short-lived helper that exists only while Bubble's Home view is on screen.
//
// Protocol (line based):
//   stdout: one compact JSON object per change. Either the Now Playing app ({"pid": …, title,
//           artwork…}) or every app with media, for Bubble's source stack ({"sources": […]}).
//   stdin:  "toggle" | "next" | "prev" | "seek <seconds>". EOF (Bubble quit or closed the
//           tab) ends the process, so the helper can never outlive Bubble.
//
// Commands always go to the Now Playing app: macOS only lets its own Control Center aim a
// command at another app's player (anything else gets "Operation not permitted").

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef id (*MRGetLocalOriginFn)(void);
typedef void (*MRGetInfoForPlayerFn)(id, Boolean, dispatch_queue_t, void (^)(CFDictionaryRef, void *));
typedef void (*MRGetStateForPlayerFn)(id, dispatch_queue_t, void (^)(unsigned int));
typedef int (*MRClientPIDFn)(id);
typedef CFStringRef (*MRClientStringFn)(id);

static MRGetInfoFn getInfo;
static MRGetIsPlayingFn getIsPlaying;
static MRGetPIDFn getPID;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

// Per-app reads for the source list. Optional: without them Bubble just shows no stack.
static MRGetClientsFn getClients;
static MRGetLocalOriginFn getLocalOrigin;
static MRGetInfoForPlayerFn getInfoForPlayer;
static MRGetStateForPlayerFn getStateForPlayer;
static MRClientPIDFn clientPID;
static MRClientStringFn clientBundle, clientParentBundle, clientName;
static BOOL canListSources;

static BOOL refreshScheduled;
static NSData *lastArtwork;
static NSArray *lastSources;
static NSMutableDictionary<NSNumber *, NSString *> *sourceArtKeys; // pid → track whose art Bubble has.
static NSMutableSet<NSNumber *> *sourcesWithArt;                    // pids Bubble holds any art for.

enum { kTogglePlayPause = 2, kNextTrack = 4, kPreviousTrack = 5 };
enum { kPlaybackStatePlaying = 1 };

static NSString *const kTitle = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kArtist = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kArtwork = @"kMRMediaRemoteNowPlayingInfoArtworkData";

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// Album art can be several MB; Bubble shows it at a fraction of that, so send a small JPEG.
static NSString *thumbnail(NSData *data, int pixels) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(pixels),
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;

    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{ (id)kCGImageDestinationLossyCompressionQuality: @0.85 });
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return jpeg.length ? [jpeg base64EncodedStringWithOptions:0] : nil;
}

static void put(NSMutableDictionary *out, NSString *key, id value) {
    if (value && value != [NSNull null]) out[key] = value;
}

static NSData *artworkData(NSDictionary *info) {
    NSData *artwork = info[kArtwork];
    return [artwork isKindOfClass:[NSData class]] ? artwork : nil;
}

static NSString *string(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void putTiming(NSMutableDictionary *out, NSDictionary *info) {
    put(out, @"album", info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    put(out, @"duration", info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    put(out, @"elapsed", info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    put(out, @"rate", info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) {
        out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    }
}

// MARK: - The Now Playing app

static void refreshNowPlaying(void) {
    dispatch_queue_t main = dispatch_get_main_queue();
    getPID(main, ^(int pid) {
        getIsPlaying(main, ^(Boolean playing) {
            getInfo(main, ^(CFDictionaryRef raw) {
                NSDictionary *info = (__bridge NSDictionary *)raw;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = playing ? @YES : @NO;
                put(out, @"title", info[kTitle]);
                put(out, @"artist", info[kArtist]);
                putTiming(out, info);

                // Art is only sent when it changes; "" tells Bubble to clear it.
                NSData *artwork = artworkData(info);
                if (artwork != lastArtwork && ![artwork isEqualToData:lastArtwork]) {
                    lastArtwork = artwork;
                    out[@"artwork"] = artwork ? (thumbnail(artwork, 192) ?: @"") : @"";
                }
                emit(out);
            });
        });
    });
}

// MARK: - Every app with media

static id playerPath(id origin, id client) {
    static Class pathClass;
    static SEL init;
    if (!pathClass) {
        pathClass = NSClassFromString(@"MRPlayerPath");
        init = sel_registerName("initWithOrigin:client:player:");
    }
    if (!pathClass || !origin || !client || ![pathClass instancesRespondToSelector:init]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)([pathClass alloc], init, origin, client, nil);
}

/// Each app's track and play state, plus its art, sent only when that app's track changes.
/// Emitted only when something Bubble shows changed.
static void refreshSources(NSArray *clients) {
    dispatch_queue_t main = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();
    id origin = getLocalOrigin();
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray arrayWithCapacity:clients.count];

    for (id client in clients) {
        id path = playerPath(origin, client);
        if (!path) continue;
        NSString *bundle = (clientParentBundle ? (__bridge NSString *)clientParentBundle(client) : nil)
            ?: (__bridge NSString *)clientBundle(client);
        NSMutableDictionary *entry = [@{
            @"pid": @(clientPID(client)),
            @"bundle": bundle ?: @"",
            @"name": (__bridge NSString *)clientName(client) ?: @"",
        } mutableCopy];
        [entries addObject:entry];

        dispatch_group_enter(group);
        getStateForPlayer(path, main, ^(unsigned int state) {
            entry[@"playing"] = state == kPlaybackStatePlaying ? @YES : @NO;
            dispatch_group_leave(group);
        });
        dispatch_group_enter(group);
        getInfoForPlayer(path, NO, main, ^(CFDictionaryRef raw, void *error) {
            (void)error;
            NSDictionary *info = (__bridge NSDictionary *)raw;
            NSString *title = string(info[kTitle]);
            entry[@"title"] = title;
            entry[@"artist"] = string(info[kArtist]);
            // Enough to show the source in the player while its block is hovered.
            putTiming(entry, info);

            NSString *key = [title stringByAppendingFormat:@"\n%@", entry[@"artist"]];
            if (title.length == 0 || [sourceArtKeys[entry[@"pid"]] isEqualToString:key]) {
                dispatch_group_leave(group);
                return;
            }
            // A new track: fetch its art once.
            getInfoForPlayer(path, YES, main, ^(CFDictionaryRef rawWithArt, void *artError) {
                (void)artError;
                NSData *artwork = artworkData((__bridge NSDictionary *)rawWithArt);
                NSString *art = artwork ? thumbnail(artwork, 192) : nil;
                NSNumber *pid = entry[@"pid"];
                if (art) {
                    entry[@"art"] = art;
                    sourceArtKeys[pid] = key;
                    [sourcesWithArt addObject:pid];
                } else if ([sourcesWithArt containsObject:pid]) {
                    // That was the previous track's art; clear it. Apps often attach art a
                    // moment after the title, so the key stays unset and the next change asks again.
                    entry[@"art"] = @"";
                    [sourcesWithArt removeObject:pid];
                }
                dispatch_group_leave(group);
            });
        });
    }

    dispatch_group_notify(group, main, ^{
        NSMutableArray *sources = [NSMutableArray array];
        for (NSMutableDictionary *entry in entries) {
            // Skip registered-but-empty sessions (an app that once played and kept its claim).
            if ([entry[@"title"] length] == 0 && ![entry[@"playing"] boolValue]) continue;
            [sources addObject:entry];
        }
        // Bubble drops what it held for a source that leaves the list.
        NSSet *listed = [NSSet setWithArray:[sources valueForKey:@"pid"]];
        for (NSNumber *pid in sourceArtKeys.allKeys) {
            if (![listed containsObject:pid]) [sourceArtKeys removeObjectForKey:pid];
        }
        [sourcesWithArt intersectSet:listed];

        // Compare without art, which is only ever included when it changes.
        NSMutableArray *comparable = [NSMutableArray arrayWithCapacity:sources.count];
        BOOL hasArt = NO;
        for (NSDictionary *entry in sources) {
            NSMutableDictionary *bare = [entry mutableCopy];
            if (bare[@"art"]) hasArt = YES;
            [bare removeObjectForKey:@"art"];
            [comparable addObject:bare];
        }
        if (hasArt || ![comparable isEqualToArray:lastSources]) {
            lastSources = comparable;
            emit(@{ @"sources": sources });
        }
    });
}

// MARK: - Refresh

static void refresh(void) {
    refreshNowPlaying();
    if (canListSources) {
        getClients(dispatch_get_main_queue(), ^(CFArrayRef raw) {
            refreshSources(raw ? [(__bridge NSArray *)raw copy] : @[]);
        });
    }
}

/// MediaRemote fires several notifications per change; coalesce them into one read.
static void scheduleRefresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        refresh();
    });
}

// MARK: - Commands

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"toggle"]) {
        sendCommand(kTogglePlayPause, NULL);
    } else if ([line isEqualToString:@"next"]) {
        sendCommand(kNextTrack, NULL);
    } else if ([line isEqualToString:@"prev"]) {
        sendCommand(kPreviousTrack, NULL);
    } else if ([line hasPrefix:@"seek "] && setElapsed) {
        setElapsed([[line substringFromIndex:5] doubleValue]);
    }
    scheduleRefresh();
}

static dispatch_source_t commandSource;

static void listenForCommands(void) {
    static NSMutableData *pending;
    pending = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char buffer[512];
        ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
        if (count <= 0) exit(0); // Bubble went away.
        [pending appendBytes:buffer length:(NSUInteger)count];

        const char *bytes = pending.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < pending.length; i++) {
            if (bytes[i] != '\n') continue;
            NSString *line = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
            if (line.length) handleCommand(line);
            start = i + 1;
        }
        [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    });
    dispatch_resume(source);
    commandSource = source; // Keep the source alive for the life of the process.
}

/// Entry point, installed by perl as an XSUB. It never returns.
__attribute__((visibility("default")))
void bubble_media_run(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mr) exit(2);

    MRRegisterFn registerForNotifications = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!registerForNotifications || !getInfo || !getIsPlaying || !getPID || !sendCommand) exit(3);

    getClients = (MRGetClientsFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
    getLocalOrigin = (MRGetLocalOriginFn)dlsym(mr, "MRMediaRemoteGetLocalOrigin");
    getInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    getStateForPlayer = (MRGetStateForPlayerFn)dlsym(mr, "MRMediaRemoteGetPlaybackStateForPlayer");
    clientPID = (MRClientPIDFn)dlsym(mr, "MRNowPlayingClientGetProcessIdentifier");
    clientBundle = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    clientName = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetDisplayName");
    canListSources = getClients && getLocalOrigin && getInfoForPlayer && getStateForPlayer
        && clientPID && clientBundle && clientName;
    sourceArtKeys = [NSMutableDictionary dictionary];
    sourcesWithArt = [NSMutableSet set];

    // Bubble reads stdout through a pipe; never let a dead reader kill us mid-write silently.
    signal(SIGPIPE, SIG_DFL);

    registerForNotifications(dispatch_get_main_queue());
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        // Every app's player, not just the Now Playing one, for the source list.
        @"kMRMediaRemoteNowPlayingApplicationDidRegister",
        @"kMRMediaRemoteNowPlayingApplicationDidUnregister",
        @"kMRMediaRemotePlayerIsPlayingDidChangeNotification",
        @"kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
    ]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            scheduleRefresh();
        }];
    }

    listenForCommands();
    refresh();
    CFRunLoopRun();
    exit(0);
}
