//
//  CRFHeartRateProcessor.m
//  CRFModuleValidation
//
//  Copyright © 2017 Sage Bionetworks. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// 1.  Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// 2.  Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation and/or
// other materials provided with the distribution.
//
// 3.  Neither the name of the copyright holder(s) nor the names of any contributors
// may be used to endorse or promote products derived from this software without
// specific prior written permission. No license is granted to the trademarks of
// the copyright holders even if such marks are included in this software.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "CRFHeartRateProcessor.h"

typedef NS_ENUM(NSInteger, MovieRecorderStatus) {
    MovieRecorderStatusIdle = 0,
    MovieRecorderStatusPreparingToRecord,
    MovieRecorderStatusRecording,
    MovieRecorderStatusFinishingRecordingPart1, // waiting for inflight buffers to be appended
    MovieRecorderStatusFinishingRecordingPart2, // calling finish writing on the asset writer
    MovieRecorderStatusFinished,    // terminal state
    MovieRecorderStatusFailed        // terminal state
}; // internal state machine


const int CRFHeartRateSettleSeconds = 3;
const int CRFHeartRateWindowSeconds = 10;
const int CRFHeartRateResolutionWidth = 192;    // lowest resolution on an iPhone 6
const int CRFHeartRateResolutionHeight = 144;   // lowest resolution on an iPhone 6
const float CRFRedThreshold = 40;

@implementation CRFHeartRateProcessor {
    dispatch_queue_t _processingQueue;
    NSMutableArray <NSNumber *> * _dataPointsHue;
    
    MovieRecorderStatus _status;
    AVAssetWriter *_assetWriter;
    BOOL _haveStartedSession;
    AVAssetWriterInput *_videoInput;
    
    __weak id<CRFHeartRateProcessorDelegate> _delegate;
    dispatch_queue_t _delegateCallbackQueue;
    
    int _minFrameCount;
}

- (instancetype)initWithDelegate:(id<CRFHeartRateProcessorDelegate>)delegate frameRate:(int)frameRate callbackQueue:(dispatch_queue_t)queue {
    NSParameterAssert(delegate != nil);
    NSParameterAssert(queue != nil);
    
    self = [super init];
    if (self) {
        _delegate = delegate;
        _delegateCallbackQueue = queue;
        _dataPointsHue = [NSMutableArray new];
        _processingQueue = dispatch_queue_create("org.sagebase.CRF.heartRateSample.processing", DISPATCH_QUEUE_SERIAL);
        _frameRate = frameRate;
        _minFrameCount = (CRFHeartRateSettleSeconds + CRFHeartRateWindowSeconds) * frameRate;
    }
    return self;
}

- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"NULL sample buffer" userInfo:nil];
        return;
    }
    
    CFRetain(sampleBuffer);
    dispatch_async(_processingQueue, ^{
        @autoreleasepool {
            
            // Process the sample
            [self processSampleBuffer:sampleBuffer];
            
            // Now, look to see if this sample should be saved to video
            @synchronized(self) {
                // From the client's perspective the movie recorder can asynchronously transition to an error state as
                // the result of an append. Because of this we are lenient when samples are appended and we are no longer recording.
                // Instead of throwing an exception we just release the sample buffers and return.
                if (_status != MovieRecorderStatusRecording) {
                    CFRelease(sampleBuffer);
                    return;
                }
            }

            if (_videoInput.readyForMoreMediaData) {
                BOOL success = [_videoInput appendSampleBuffer:sampleBuffer];
                if (!success) {
                    NSError *error = _assetWriter.error;
                    @synchronized(self) {
                        [self transitionToStatus:MovieRecorderStatusFailed error:error];
                    }
                }
            } else {
                NSLog( @"video input not ready for more media data, dropping buffer");
            }
            CFRelease(sampleBuffer);
        }
    });
}

// Algorithms adapted from: https://github.com/lehn0058/ATHeartRate (March 19, 2015)
// with additional modifications by: https://github.com/Litekey/heartbeat-cordova-plugin (July 30, 2015)
// and modifications by Shannon Young (February, 2017)

- (BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CVImageBufferRef cvimgRef = CMSampleBufferGetImageBuffer(sampleBuffer);
    return [self processImageBuffer:cvimgRef timestamp:pts];
}

- (BOOL)processImageBuffer:(CVImageBufferRef)cvimgRef timestamp:(CMTime)pts {
    
    // Lock the image buffer
    CVPixelBufferLockBaseAddress(cvimgRef,0);
    
    // access the data
    uint64_t width = CVPixelBufferGetWidth(cvimgRef);
    uint64_t height = CVPixelBufferGetHeight(cvimgRef);
    
    // get the raw image bytes
    uint8_t *buf=(uint8_t *) CVPixelBufferGetBaseAddress(cvimgRef);
    size_t bprow=CVPixelBufferGetBytesPerRow(cvimgRef);

    // Calculate average
    float r = 0, g = 0, b = 0;
    long redCount = 0;
    
    long widthScaleFactor = 1;
    long heightScaleFactor = 1;
    if ((width > CRFHeartRateResolutionWidth) && (height > CRFHeartRateResolutionHeight)) {
        // Belt & Suspenders: If at some point there is a camera released without 420v format
        // then this will downsample the resolution to 192x144 (with round number scaling)
        widthScaleFactor = floor((double)width / (double)CRFHeartRateResolutionWidth);
        heightScaleFactor = floor((double)height / (double)CRFHeartRateResolutionHeight);
    }
    
    // Get the average rgb values for the entire image.
    for (int y = 0; y < height; y += heightScaleFactor) {
        for (int x = 0; x < width * 4; x += (4 * widthScaleFactor)) {
            float red = buf[x + 2];
            float green = buf[x + 1];
            float blue = buf[x];
            
            float h = [self getRedHueFromRed:red green:green blue:blue];
            if (h >= 0) {
                redCount++;
            }
            
            r += red;
            g += green;
            b += blue;
        }
        buf += bprow;
    }
    r /= 255 * (float)((width * height) / (widthScaleFactor * heightScaleFactor));
    g /= 255 * (float)((width * height) / (widthScaleFactor * heightScaleFactor));
    b /= 255 * (float)((width * height) / (widthScaleFactor * heightScaleFactor));
    float redLevel = redCount / (float)((width * height) / (widthScaleFactor * heightScaleFactor));
    
    // Unlock the image buffer
    CVPixelBufferUnlockBaseAddress(cvimgRef,0);
    
    // Get the HSV values
    float hue, sat, bright;
    [self getHSVFromRed:r green:g blue:b hue:&hue saturation:&sat brightness:&bright];
    
    BOOL isCoveringLens = [self isCoveringLens:hue saturation:sat brightness:bright redLevel:redLevel];
    
    [self addDataPoint:hue isCoveringLens:isCoveringLens];
    
    // Create a struct to return the pixel average
    struct CRFPixelSample sample;
    sample.uptime = (double)(pts.value) / (double)(pts.timescale);
    sample.red = (double)r;
    sample.green = (double)g;
    sample.blue = (double)b;
    sample.hue = (double)hue;
    sample.saturation = (double)sat;
    sample.brightness = (double)bright;
    sample.redLevel = (double)redLevel;
    sample.isCoveringLens = isCoveringLens;
        
    // Alert the delegate
    dispatch_async(_delegateCallbackQueue, ^{
        [_delegate processor:self didCaptureSample:sample];
    });
    
    return isCoveringLens;
}

- (float)getRedHueFromRed:(float)r green:(float)g blue:(float)b {
    if ((r < g) || (r < b)) {
        return -1;
    }
    float min = MIN(g, b);
    float delta = r - min;
    if (delta < CRFRedThreshold) {
        return -1;
    }
    float hue = 60*((g - b) / delta);
    if (hue < 0) {
        hue += 360;
    }
    return hue;
}

- (void)getHSVFromRed:(float)r green:(float)g blue:(float)b hue:(float *)h saturation:(float *)s brightness:(float *)v {
    
    float min = MIN(r, MIN(g, b));
    float max = MAX(r, MAX(g, b));
    float delta = max - min;
    if (((int)round(delta * 1000.0) == 0) || ((int)round(delta * 1000.0) == 0)) {
        *h = -1;
        *s = 0;
        *v = 0;
        return;
    }
    
    float hue;
    if (r == max) {
        hue = (g - b) / delta;
    } else if (g == max) {
        hue = 2 + (b - r) / delta;
    } else {
        hue = 4 + (r - g) / delta;
    }
    hue *= 60;
    if (hue < 0) {
        hue += 360;
    }
    
    *v = max;
    *s = delta / max;
    *h = hue;
}

- (BOOL)isCoveringLens:(double)hue saturation:(float)saturation brightness:(float)brightness redLevel:(float)redLevel {
    //NSLog(@"hue:%0.3f, saturation:%0.3f, brightness:%0.3f, redLevel:%0.3f", hue, saturation, brightness, redLevel);
    return (hue >= 0) && (hue <= 30 || hue >= 350) && (saturation >= 0.7) && (redLevel >= 0.9);
}

- (void)addDataPoint:(double)hue isCoveringLens:(BOOL)isCoveringLens {
    if (isCoveringLens) {
        // Since the hue for blood is in the red zone which cross the degrees point,
        // offset that value by 180.
        double offsetHue = hue + 180.0;
        if (offsetHue > 360.0) {
            offsetHue -= 360.0;
        }
        [_dataPointsHue addObject:@(offsetHue)];
    } else {
        // If this is not a valid data point then strip out all the points
        [_dataPointsHue removeAllObjects];
    }
}

- (NSInteger)calculateBPM {
    
    // If a valid heart rate cannot be calculated then return -1 as an invalid marker
    if (_dataPointsHue.count < _minFrameCount) {
        return -1;
    }
    
    // Get a window of data points that is the length of the window we are looking at
    NSUInteger len = CRFHeartRateWindowSeconds * _frameRate;
    NSArray *dataPoints = [_dataPointsHue subarrayWithRange:NSMakeRange(_dataPointsHue.count - len, len)];
    
    // If we have enough data points then remove from beginning
    if (_dataPointsHue.count > _minFrameCount) {
        NSInteger len = _dataPointsHue.count - _minFrameCount;
        [_dataPointsHue removeObjectsInRange:NSMakeRange(0, len)];
    }
    
    // If the heart rate calculated is too low, then it isn't valid
    NSInteger heartRate = [self calculateBPMWithDataPoints:dataPoints];
    return heartRate >= 40 ? heartRate : -1;
}

- (NSInteger)calculateBPMWithDataPoints:(NSArray *)dataPoints {

    // Get a window of data points that is the length of the window we are looking at
    NSUInteger len = CRFHeartRateWindowSeconds * _frameRate;
    if (dataPoints.count < len) { return -1; }
    NSArray *inputPoints = [dataPoints subarrayWithRange:NSMakeRange(dataPoints.count - len, len)];
    
    NSArray *bandpassFilteredItems = [self butterworthBandpassFilter:inputPoints];
    NSArray *smoothedBandpassItems = [self medianSmoothing:bandpassFilteredItems];
    int peak = [self medianPeak:smoothedBandpassItems];
    NSInteger heartRate = 60 * _frameRate / peak;
    return heartRate;
}

- (int)medianPeak:(NSArray *)inputData
{
    NSMutableArray *peaks = [[NSMutableArray alloc] init];
    int count = 4;
    for (int i = 3; i < inputData.count - 3; i++, count++)
    {
        if (inputData[i] > 0 &&
            [inputData[i] doubleValue] > [inputData[i-1] doubleValue] &&
            [inputData[i] doubleValue] > [inputData[i-2] doubleValue] &&
            [inputData[i] doubleValue] > [inputData[i-3] doubleValue] &&
            [inputData[i] doubleValue] >= [inputData[i+1] doubleValue] &&
            [inputData[i] doubleValue] >= [inputData[i+2] doubleValue] &&
            [inputData[i] doubleValue] >= [inputData[i+3] doubleValue]
            )
        {
            [peaks addObject:@(count)];
            i += 3;
            count = 3;
        }
    }
    if (peaks.count == 0) {
        return -1;
    }
    [peaks setObject:@([peaks[0] integerValue] + count + 3) atIndexedSubscript: 0];
    [peaks sortUsingComparator:^(NSNumber *a, NSNumber *b){
        return [a compare:b];
    }];
    int medianPeak = (int)[peaks[peaks.count * 2 / 3] integerValue];
    return (medianPeak != 0) ? medianPeak : -1;
}

- (NSArray *)butterworthBandpassFilter:(NSArray *)inputData {
    const int NZEROS = 8;
    const int NPOLES = 8;
    static float xv[NZEROS+1], yv[NPOLES+1];
    
    // http://www-users.cs.york.ac.uk/~fisher/mkfilter/trad.html
    // Butterworth Bandpass filter
    // 4th order
    // sample rate - varies between possible camera frequencies. Either 30, 60, 120, or 240 FPS
    // corner1 freq. = 0.667 Hz (assuming a minimum heart rate of 40 bpm, 40 beats/60 seconds = 0.667 Hz)
    // corner2 freq. = 3.333 Hz (assuming a maximum heart rate of 250 bpm, 200 beats/60 secods = 3.333 Hz)
    // Bandpass filter was chosen because it removes frequency noise outside of our target range (both higher and lower)
    
    double dGain;
    switch (_frameRate) {
        case 60: // fps
            dGain = 3.700200091e+03; break;
        default: // 30 fps
            dGain = 1.232232910e+02; break;
    }

    NSMutableArray *outputData = [[NSMutableArray alloc] init];
    for (NSNumber *number in inputData) {
        double input = number.doubleValue;
        
        for (int nn=0; nn < NZEROS; nn++) {
            xv[nn] = xv[nn + 1];
            yv[nn] = yv[nn + 1];
        }
        xv[NZEROS] = input / dGain;
        
        switch (_frameRate) {
            case 60:    // fps
                yv[8] =   (xv[0] + xv[8]) - 4 * (xv[2] + xv[6]) + 6 * xv[4]
                + ( -0.4807840433 * yv[0]) + (  4.1451027450 * yv[1])
                + (-15.7113442660 * yv[2]) + ( 34.1943207190 * yv[3])
                + (-46.7368439100 * yv[4]) + ( 41.0778389140 * yv[5])
                + (-22.6708290820 * yv[6]) + (  7.1825386733 * yv[7]);
                break;
                
            default:    // 30 fps
                yv[8] = (xv[0] + xv[8]) - 4 * (xv[2] + xv[6]) + 6 * xv[4]
                + ( -0.1397436053 * yv[0]) + (  1.2948188815 * yv[1])
                + ( -5.4070037946 * yv[2]) + ( 13.2683981280 * yv[3])
                + (-20.9442560520 * yv[4]) + ( 21.7932169160 * yv[5])
                + (-14.5817197500 * yv[6]) + (  5.7161939252 * yv[7]);
                break;
        }

        [outputData addObject:@(yv[NPOLES])];
    }
    
    return outputData;
}

// Smoothed data helps remove outliers that may be caused by interference, finger movement or pressure changes.
// This will only help with small interference changes.
// This also helps keep the data more consistent.
- (NSArray *)medianSmoothing:(NSArray *)inputData {
    NSMutableArray *newData = [[NSMutableArray alloc] init];
    
    for (int i = 0; i < inputData.count; i++) {
        if (i == 0 ||
            i == 1 ||
            i == 2 ||
            i == inputData.count - 1 ||
            i == inputData.count - 2 ||
            i == inputData.count - 3)        {
            [newData addObject:inputData[i]];
        } else {
            NSArray *items = [@[
                                inputData[i-2],
                                inputData[i-1],
                                inputData[i],
                                inputData[i+1],
                                inputData[i+2],
                                ] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES]]];
            
            [newData addObject:items[2]];
        }
    }
    
    return newData;
}

#pragma mark - Video recording

// Adapted from https://developer.apple.com/library/content/samplecode/RosyWriter

- (void)startRecordingToURL:(NSURL *)url startTime:(CMTime)time formatDescription:(CMFormatDescriptionRef)formatDescription {
    NSParameterAssert(url != nil);
    NSParameterAssert(formatDescription != nil);
    
    @synchronized(self) {
        if (_status != MovieRecorderStatusIdle) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already prepared, cannot prepare again" userInfo:nil];
            return;
        }
        
        [self transitionToStatus:MovieRecorderStatusPreparingToRecord error:nil];
        _videoURL = url;
    }
    
    dispatch_async(_processingQueue, ^{
        @autoreleasepool {
            
            NSError *error = nil;
            // AVAssetWriter will not write over an existing file.
            [[NSFileManager defaultManager] removeItemAtURL:_videoURL error:NULL];
            
            // Open a new asset writer
            _assetWriter = [[AVAssetWriter alloc] initWithURL:_videoURL fileType:AVFileTypeQuickTimeMovie error:&error];
            
            // Create and add inputs
            if (!error) {
                [self setupAssetWriterVideoInputWithSourceFormatDescription:formatDescription error:&error];
            }
            
            if (!error) {
                BOOL success = [_assetWriter startWriting];
                if (!success) {
                    error = _assetWriter.error;
                } else {
                    [_assetWriter startSessionAtSourceTime:time];
                }
            }
            
            @synchronized(self) {
                if (error) {
                    [self transitionToStatus:MovieRecorderStatusFailed error:error];
                } else {
                    [self transitionToStatus:MovieRecorderStatusRecording error:nil];
                }
            }
        }
    } );
}

// call under @synchonized(self)
- (void)transitionToStatus:(MovieRecorderStatus)newStatus error:(NSError *)error {
    if (newStatus == _status) { return; }

    // terminal states
    BOOL isTerminalStatus = (newStatus == MovieRecorderStatusFinished) || (newStatus == MovieRecorderStatusFailed);
    if (isTerminalStatus) {
        // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
        dispatch_async(_processingQueue, ^{
            [self teardownAssetWriterAndInputs];
            if (newStatus == MovieRecorderStatusFailed) {
                [[NSFileManager defaultManager] removeItemAtURL:_videoURL error:NULL];
                _videoURL = nil;
            }
        });
    }
    
    // Update the status
    _status = newStatus;
    
    BOOL shouldNotifyDelegate = isTerminalStatus || (newStatus == MovieRecorderStatusRecording);
    if (shouldNotifyDelegate) {
        dispatch_async(_delegateCallbackQueue, ^{
            @autoreleasepool {
                switch (newStatus) {
                    case MovieRecorderStatusFailed:
                        if ([_delegate respondsToSelector:@selector(processor:didFailToRecordWithError:)]) {
                            [_delegate processor:self didFailToRecordWithError:error];
                        }
                        break;
                    default:
                        break;
                }
            }
        });
    }
}

- (void)stopRecordingWithCompletion:(void (^)(void))completion {
    @synchronized(self) {
        BOOL shouldFinishRecording = NO;
        switch (_status) {
            case MovieRecorderStatusIdle:
            case MovieRecorderStatusPreparingToRecord:
            case MovieRecorderStatusFinishingRecordingPart1:
            case MovieRecorderStatusFinishingRecordingPart2:
            case MovieRecorderStatusFinished:
                @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Not recording" userInfo:nil];
                break;
            case MovieRecorderStatusFailed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                break;
            case MovieRecorderStatusRecording:
                shouldFinishRecording = YES;
                break;
        }
        
        if (shouldFinishRecording) {
            [self transitionToStatus:MovieRecorderStatusFinishingRecordingPart1 error:nil];
        }
        else {
            return;
        }
    }
    
    dispatch_async(_processingQueue, ^{
        @autoreleasepool {
            @synchronized(self) {
                // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                if (_status != MovieRecorderStatusFinishingRecordingPart1) {
                    return;
                }
                
                // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more
                // buffers will be appended.
                [self transitionToStatus:MovieRecorderStatusFinishingRecordingPart2 error:nil];
            }
            
            [_assetWriter finishWritingWithCompletionHandler:^{
                @synchronized(self) {
                    NSError *error = _assetWriter.error;
                    if (error) {
                        [self transitionToStatus:MovieRecorderStatusFailed error:error];
                    } else {
                        [self transitionToStatus:MovieRecorderStatusFinished error:nil];
                    }
                }
                
                if (completion) {
                    completion();
                }
            }];
        }
    });
}

- (BOOL)setupAssetWriterVideoInputWithSourceFormatDescription:(CMFormatDescriptionRef)videoFormatDescription error:(NSError **)errorOut {
    
    // Setup the video settings
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription);
    int numPixels = dimensions.width * dimensions.height;
    float bitsPerPixel = 4.05; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetLow.
    int bitsPerSecond = numPixels * bitsPerPixel;
    
    NSDictionary *compressionProperties = @{ AVVideoAverageBitRateKey : @(bitsPerSecond),
                                             AVVideoExpectedSourceFrameRateKey : @(_frameRate),
                                             AVVideoMaxKeyFrameIntervalKey : @(_frameRate) };
    
    NSDictionary *videoSettings = @{ AVVideoCodecKey : AVVideoCodecTypeH264,
                       AVVideoWidthKey : @(dimensions.width),
                       AVVideoHeightKey : @(dimensions.height),
                       AVVideoCompressionPropertiesKey : compressionProperties };
    
    if ([_assetWriter canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
        _videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings sourceFormatHint:videoFormatDescription];
        _videoInput.expectsMediaDataInRealTime = YES;
        _videoInput.transform = CGAffineTransformIdentity;
        
        if ([_assetWriter canAddInput:_videoInput]) {
            [_assetWriter addInput:_videoInput];
        }
        else {
            if (errorOut) {
                *errorOut = [[self class] cannotSetupInputError];
            }
            return NO;
        }
    }
    else {
        if (errorOut) {
            *errorOut = [[self class] cannotSetupInputError];
        }
        return NO;
    }
    
    return YES;
}

+ (NSError *)cannotSetupInputError {
    NSString *localizedDescription = NSLocalizedString( @"Recording cannot be started", nil);
    NSString *localizedFailureReason = NSLocalizedString( @"Cannot setup asset writer input.", nil);
    NSDictionary *errorDict = @{ NSLocalizedDescriptionKey : localizedDescription,
                                 NSLocalizedFailureReasonErrorKey : localizedFailureReason };
    return [NSError errorWithDomain:@"org.sagebase.CRF.HeartRateProcessor" code:-1 userInfo:errorDict];
}

- (void)teardownAssetWriterAndInputs {
    _videoInput = nil;
    _assetWriter = nil;
}

@end
