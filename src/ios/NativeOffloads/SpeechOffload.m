//
//  SpeechOffload.m
//  MinisApp
//
//  Native offload handler for `apple-speech`.
//  Subcommands: transcribe, languages, status
//

#import <Foundation/Foundation.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>
#include <math.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#elif __has_include("MinisApp-Swift.h")
#import "MinisApp-Swift.h"
#else
@class AudioSessionCaptureToken;
@interface AudioSessionOffloadBridge : NSObject
+ (void)beginCapture;
+ (void)endCapture;
+ (AudioSessionCaptureToken *)acquireCapture;
+ (void)releaseCapture:(AudioSessionCaptureToken *)token;
@end
#endif

static NSString *const TOOL_NAME = @"apple-speech";

static NSString *const HELP_TEXT =
    @"apple-speech - Speech recognition (audio → text)\n"
     "\n"
     "USAGE:\n"
     "  apple-speech <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  transcribe   Transcribe from system mic or an audio file\n"
     "  languages    List available speech recognition locales\n"
     "  status       Check speech recognition availability\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "  --source <mic|path>  Source is system mic (default) or audio file path\n"
     "  --duration <seconds> Recording duration for mic source (default: 10, max: 60)\n"
     "  --language <locale>  Recognition locale (default: auto, e.g. en-US, zh-CN)\n"
     "  --on-device          Force on-device recognition\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-speech transcribe --duration 5\n"
     "  apple-speech transcribe --source mic --duration 5\n"
     "  apple-speech transcribe --source /var/minis/attachments/meeting.m4a\n"
     "  apple-speech transcribe --language zh-CN --duration 15\n"
     "  apple-speech transcribe --on-device\n"
     "  apple-speech languages\n"
     "  apple-speech status\n";

static BOOL source_is_mic(NSString *source) {
    if (!source || source.length == 0) return YES;

    NSString *normalized = [[source stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [normalized isEqualToString:@"mic"]
        || [normalized isEqualToString:@"system-mic"]
        || [normalized isEqualToString:@"system_mic"]
        || [normalized isEqualToString:@"microphone"];
}

static NSString *resolved_audio_file_path(NSString *sourcePath) {
    if (!sourcePath || sourcePath.length == 0) return nil;

    NSString *candidate = [sourcePath stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (candidate.length == 0) return nil;

    if (![candidate hasPrefix:@"/"]) {
        return candidate;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mapped = noff_resolve_host_path(candidate);
    BOOL mappedExists = mapped && [fm fileExistsAtPath:mapped];
    BOOL rawExists = [fm fileExistsAtPath:candidate];

    if (mappedExists) return mapped;
    if (rawExists) return candidate;
    return mapped ?: candidate;
}

static NSString *auth_status_string(SFSpeechRecognizerAuthorizationStatus status) {
    switch (status) {
        case SFSpeechRecognizerAuthorizationStatusAuthorized:    return @"authorized";
        case SFSpeechRecognizerAuthorizationStatusDenied:        return @"denied";
        case SFSpeechRecognizerAuthorizationStatusRestricted:    return @"restricted";
        case SFSpeechRecognizerAuthorizationStatusNotDetermined: return @"not_determined";
        default: return @"unknown";
    }
}

static int cmd_status(int stdout_fd, BOOL compact, BOOL quiet) {
    SFSpeechRecognizerAuthorizationStatus authStatus = [SFSpeechRecognizer authorizationStatus];
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] init];

    NSDictionary *data = @{
        @"authorization_status": auth_status_string(authStatus),
        @"is_available": @(recognizer.isAvailable),
        @"locale": recognizer.locale.localeIdentifier ?: @"unknown",
        @"supports_on_device": @(recognizer.supportsOnDeviceRecognition),
    };

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"status", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_languages(int stdout_fd, BOOL compact, BOOL quiet) {
    NSSet<NSLocale *> *locales = [SFSpeechRecognizer supportedLocales];
    NSMutableArray *items = [NSMutableArray array];

    for (NSLocale *locale in locales) {
        NSString *identifier = locale.localeIdentifier;
        NSString *displayName = [[NSLocale currentLocale] localizedStringForLocaleIdentifier:identifier];
        [items addObject:@{
            @"locale": identifier,
            @"display_name": displayName ?: identifier,
        }];
    }

    // Sort by locale identifier
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"locale"] compare:b[@"locale"]];
    }];

    NSDictionary *data = @{
        @"locales": items,
        @"count": @(items.count),
    };

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"languages", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// Serial queue to prevent concurrent authorization dialogs
static dispatch_queue_t authQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.openminis.speech.auth", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static int cmd_transcribe(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    // Check authorization
    __block SFSpeechRecognizerAuthorizationStatus authStatus = [SFSpeechRecognizer authorizationStatus];
    __block BOOL authTimedOut = NO;

    if (authStatus == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        if ([NSThread isMainThread]) {
            NSDictionary *err = noff_json_error(
                TOOL_NAME, @"transcribe", NOFF_ERR_INTERNAL_ERROR,
                @"Speech authorization must be requested from a background tool worker.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }

        dispatch_sync(authQueue(), ^{
            // Re-check inside queue in case another thread already resolved it
            authStatus = [SFSpeechRecognizer authorizationStatus];
            if (authStatus != SFSpeechRecognizerAuthorizationStatusNotDetermined) return;

            dispatch_semaphore_t authSem = dispatch_semaphore_create(0);
            __block SFSpeechRecognizerAuthorizationStatus newStatus =
                SFSpeechRecognizerAuthorizationStatusNotDetermined;
            dispatch_async(dispatch_get_main_queue(), ^{
                [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
                    newStatus = status;
                    dispatch_semaphore_signal(authSem);
                }];
            });
            long authWait = dispatch_semaphore_wait(
                authSem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
            if (authWait != 0) {
                authTimedOut = YES;
                return;
            }
            authStatus = newStatus;
        });
    }

    if (authTimedOut) {
        NSDictionary *err = noff_json_error(
            TOOL_NAME, @"transcribe", NOFF_ERR_TIMEOUT,
            @"Timed out while waiting for Speech Recognition permission.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    if (authStatus != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                             NOFF_ERR_AUTHORIZATION_DENIED,
                                             [NSString stringWithFormat:@"Speech recognition not authorized (status: %@). "
                                              "To grant access, open Settings > Privacy & Security > Speech Recognition "
                                              "and enable Minis.",
                                              auth_status_string(authStatus)]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_AUTH_DENIED;
    }

    // Parse options
    NSString *sourceArg = noff_find_arg(argc, argv, "--source");
    if (noff_has_flag(argc, argv, "--source") && !sourceArg) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--source requires a value: mic or an audio file path.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    BOOL micSource = source_is_mic(sourceArg);
    NSString *resolvedFilePath = nil;
    if (!micSource) {
        NSString *normalized = [[sourceArg stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if ([normalized isEqualToString:@"audio-file"] || [normalized isEqualToString:@"audio_file"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"When --source is an audio file, pass the file path directly (e.g. --source /var/minis/attachments/audio.m4a).");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }

        resolvedFilePath = resolved_audio_file_path(sourceArg);
        BOOL isDir = NO;
        if (!resolvedFilePath
            || ![[NSFileManager defaultManager] fileExistsAtPath:resolvedFilePath isDirectory:&isDir]
            || isDir) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                                 NOFF_ERR_INVALID_ARGS,
                                                 [NSString stringWithFormat:@"Audio file not found: %@", sourceArg ?: @"(null)"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
    }

    NSString *durationStr = noff_find_arg(argc, argv, "--duration");
    NSTimeInterval duration = durationStr ? [durationStr doubleValue] : 10.0;
    if (duration <= 0) duration = 10.0;
    if (duration > 60) duration = 60.0;
    NSString *langStr = noff_find_arg(argc, argv, "--language");
    BOOL onDevice = noff_has_flag(argc, argv, "--on-device");

    // Create recognizer
    SFSpeechRecognizer *recognizer;
    if (langStr) {
        NSLocale *locale = [NSLocale localeWithLocaleIdentifier:langStr];
        recognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    } else {
        recognizer = [[SFSpeechRecognizer alloc] init];
    }

    if (!recognizer || !recognizer.isAvailable) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                             NOFF_ERR_NOT_AVAILABLE,
                                             @"Speech recognizer not available for the specified locale.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_NOT_AVAILABLE;
    }

    // Shared recognition result state
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *finalText = nil;
    __block NSArray *finalSegments = nil;
    __block BOOL isFinal = NO;
    __block NSError *recognitionError = nil;
    __block BOOL timedOut = NO;
    __block SFSpeechRecognitionTask *recognitionTask = nil;

    // Mic capture lifecycle. Every terminal path funnels through the idempotent
    // main-thread cleanup block so the recording intent and input tap cannot leak.
    __block AVAudioEngine *audioEngine = nil;
    __block AVAudioInputNode *inputNode = nil;
    __block SFSpeechAudioBufferRecognitionRequest *bufferRequest = nil;
    __block BOOL tapInstalled = NO;
    __block AudioSessionCaptureToken *captureToken = nil;
    __block BOOL captureCleaned = NO;
    __block BOOL operationExpired = NO;
    NSObject *lifecycleLock = [[NSObject alloc] init];
    dispatch_group_t cleanupGroup = micSource ? dispatch_group_create() : nil;
    if (cleanupGroup) dispatch_group_enter(cleanupGroup);

    void (^cleanupMicOnMain)(BOOL) = ^(BOOL cancelRecognition) {
        NSCAssert([NSThread isMainThread], @"Speech capture cleanup must stay on main");
        if (!micSource || captureCleaned) return;
        captureCleaned = YES;

        if (audioEngine.isRunning) {
            [audioEngine stop];
        }
        if (tapInstalled && inputNode) {
            [inputNode removeTapOnBus:0];
            tapInstalled = NO;
        }
        if (bufferRequest) {
            [bufferRequest endAudio];
        }
        if (cancelRecognition && recognitionTask) {
            [recognitionTask cancel];
        }
        if (captureToken) {
            [AudioSessionOffloadBridge releaseCapture:captureToken];
            captureToken = nil;
        }
        if (cleanupGroup) dispatch_group_leave(cleanupGroup);
    };

    if (!micSource) {
        NSURL *fileURL = [NSURL fileURLWithPath:resolvedFilePath];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
        Float64 fileDuration = CMTimeGetSeconds(asset.duration);
        NSTimeInterval waitTimeout = 120.0;
        if (isfinite(fileDuration) && fileDuration > 0.0) {
            waitTimeout = fmin(300.0, fmax(30.0, fileDuration + 20.0));
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            SFSpeechURLRecognitionRequest *request =
                [[SFSpeechURLRecognitionRequest alloc] initWithURL:fileURL];
            request.shouldReportPartialResults = YES;

            if (onDevice && recognizer.supportsOnDeviceRecognition) {
                request.requiresOnDeviceRecognition = YES;
            }

            recognitionTask =
                [recognizer recognitionTaskWithRequest:request
                                         resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                if (error) {
                    recognitionError = error;
                    dispatch_semaphore_signal(sem);
                    return;
                }
                if (result) {
                    finalText = result.bestTranscription.formattedString;
                    NSMutableArray *segs = [NSMutableArray array];
                    for (SFTranscriptionSegment *seg in result.bestTranscription.segments) {
                        [segs addObject:@{
                            @"substring": seg.substring ?: @"",
                            @"timestamp": @(seg.timestamp),
                            @"duration": @(seg.duration),
                            @"confidence": @(seg.confidence),
                        }];
                    }
                    finalSegments = segs;
                    isFinal = result.isFinal;
                    if (result.isFinal) {
                        dispatch_semaphore_signal(sem);
                    }
                }
            }];
        });

        long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTimeout * NSEC_PER_SEC)));
        timedOut = (waitResult != 0);
        if (timedOut) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [recognitionTask cancel];
            });
        }
    } else {
        // Set up audio engine and recognition request (mic source)
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (lifecycleLock) {
                if (operationExpired) {
                    cleanupMicOnMain(YES);
                    return;
                }
            }

            captureToken = [AudioSessionOffloadBridge acquireCapture];
            audioEngine = [[AVAudioEngine alloc] init];
            bufferRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
            bufferRequest.shouldReportPartialResults = YES;

            if (onDevice && recognizer.supportsOnDeviceRecognition) {
                bufferRequest.requiresOnDeviceRecognition = YES;
            }

            recognitionTask =
                [recognizer recognitionTaskWithRequest:bufferRequest
                                         resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                if (error) {
                    recognitionError = error;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        cleanupMicOnMain(YES);
                    });
                    dispatch_semaphore_signal(sem);
                    return;
                }
                if (result) {
                    finalText = result.bestTranscription.formattedString;
                    NSMutableArray *segs = [NSMutableArray array];
                    for (SFTranscriptionSegment *seg in result.bestTranscription.segments) {
                        [segs addObject:@{
                            @"substring": seg.substring ?: @"",
                            @"timestamp": @(seg.timestamp),
                            @"duration": @(seg.duration),
                            @"confidence": @(seg.confidence),
                        }];
                    }
                    finalSegments = segs;
                    isFinal = result.isFinal;
                    if (result.isFinal) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            cleanupMicOnMain(NO);
                        });
                        dispatch_semaphore_signal(sem);
                    }
                }
            }];

            inputNode = audioEngine.inputNode;
            AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
            [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat
                                 block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                [bufferRequest appendAudioPCMBuffer:buffer];
            }];
            tapInstalled = YES;

            [audioEngine prepare];
            NSError *startError = nil;
            [audioEngine startAndReturnError:&startError];
            if (startError) {
                recognitionError = startError;
                cleanupMicOnMain(YES);
                dispatch_semaphore_signal(sem);
                return;
            }

            // Stop after duration
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                cleanupMicOnMain(NO);

                // Give recognition a moment to finalize
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                    if (!isFinal) {
                        [recognitionTask cancel];
                    }
                    dispatch_semaphore_signal(sem);
                });
            });
        });

        // Wait for duration + processing time
        long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 10) * NSEC_PER_SEC)));
        timedOut = (waitResult != 0);
        if (timedOut) {
            @synchronized (lifecycleLock) {
                operationExpired = YES;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            cleanupMicOnMain(timedOut);
        });
        // Cleanup is expected to be immediate; never let a wedged main queue
        // turn this native command into another unbounded shell process.
        dispatch_group_wait(
            cleanupGroup,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }

    if (timedOut && !finalText) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                             NOFF_ERR_TIMEOUT,
                                             @"Recognition timed out before receiving results.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    if (recognitionError && !finalText) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"transcribe",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             recognitionError.localizedDescription ?: @"Recognition failed");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSDictionary *data = @{
        @"text": finalText ?: @"",
        @"segments": finalSegments ?: @[],
        @"locale": recognizer.locale.localeIdentifier ?: @"unknown",
        @"is_final": @(isFinal),
        @"source": micSource ? @"mic" : (sourceArg ?: @"mic"),
        @"source_type": micSource ? @"mic" : @"audio_file",
        @"duration_seconds": @(micSource ? duration : 0),
        @"on_device": @(onDevice && recognizer.supportsOnDeviceRecognition),
    };

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"transcribe", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int speech_handler(int argc, char **argv,
                           int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    if ([subcmd isEqualToString:@"transcribe"]) {
        return cmd_transcribe(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"languages"]) {
        return cmd_languages(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"status"]) {
        return cmd_status(stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: transcribe, languages, status. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void speech_offload_register(void) {
    int err = native_offload_add_handler("apple-speech", speech_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-speech");
        NSLog(@"NativeOffloads: apple-speech handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-speech handler (err=%d)", err);
    }
}
