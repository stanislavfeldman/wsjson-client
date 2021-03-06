#import "WsJsonClient.h"

@implementation WsJsonClient {
    SRWebSocket* socket;
    BOOL connected;
    NSString* serverUrl;
    NSMutableArray* requestsQueue;
    NSMutableDictionary* callbacks;
    NSMutableDictionary* errbacks;
    NSString* apiKey;
    NSTimeInterval timeout;
    NSTimer* timeoutTimer;
    NSString* cert;
    BOOL needResend;
}

+ (WsJsonClient*) sharedInstance {
    static dispatch_once_t pred;
    static WsJsonClient* instance = nil;
    
    dispatch_once(&pred, ^{
        instance = [self new];
    });
    return instance;
}

- (void) connectToHost:(NSString*)host port:(int)port {
    [self connectToHost:host port:port apiKey:nil timeout:3 resend:YES secure:NO cert:nil];
}

// cert is der certificate name in project
- (void) connectToHost:(NSString*)host port:(int)port apiKey:(NSString*)apiKey0 timeout:(NSTimeInterval)timeout0 resend:(BOOL)needResend0 secure:(BOOL)secure cert:(NSString*)certName {
    NSString* pathPattern = @"ws://%@:%i";
    if(secure)
        pathPattern = @"wss://%@:%i";
    serverUrl = [NSString stringWithFormat:pathPattern, host, port];
    apiKey = apiKey0;
    timeout = timeout0;
    cert = certName;
    [self reconnect];
}

- (void) request:(NSString*)url callback:(WsJsonCallback)callback errback:(WSJsonErrback)errback {
    [self request:url params:nil callback:callback errback:errback];
}

- (void) request:(NSString*)url params:(NSDictionary*)params callback:(WsJsonCallback)callback errback:(WSJsonErrback)errback {
    NSMutableDictionary* result = nil;
    if(params)
        result = [params mutableCopy];
    else
        result = [NSMutableDictionary new];
    [result setValue:url forKey:@"url"];
    if(apiKey)
        [result setValue:apiKey forKey:@"api_key"];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (!jsonData) {
        if(errback)
            errback(nil);
        return;
    }
    if(callback)
        [callbacks setValue:callback forKey:url];
    if(errback)
        [errbacks setValue:errback forKey:url];
    NSString* request = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if(connected)
        [socket send:request];
    else
        [requestsQueue addObject:request];
}

# pragma mark delegate methods
- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
    NSString* url = [json valueForKey:@"url"];
    NSNumber* success = [json valueForKey:@"success"];
    if(![success isEqualToNumber:@YES]) {
        NSString* errorMsg = [json valueForKey:@"error"];
        if(!errorMsg)
            errorMsg = @"Сервер не отвечает";
        WSJsonErrback errback = [errbacks valueForKey:url];
        if(errback) {
            [callbacks removeObjectForKey:url];
            [errbacks removeObjectForKey:url];
            errback(errorMsg);
        }
        // нужно ли посылать уведомление об ошибке?
    }
    else {
        WsJsonCallback callback = [callbacks valueForKey:url];
        if(callback) {
            [callbacks removeObjectForKey:url];
            [errbacks removeObjectForKey:url];
            callback(json);
        }
        else
            [[NSNotificationCenter defaultCenter] postNotificationName:url object:json];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    NSLog(@"websocket connection error");
    [self cancelTimeoutTimer];
    connected = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:WSJSON_CONNECTION_ERROR object:nil];
    [self onError];
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    NSLog(@"websocket connected to %@", webSocket.url);
    [self cancelTimeoutTimer];
    connected = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:WSJSON_CONNECTED object:nil];
    if(needResend)
        [self resendQueue];
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    NSLog(@"websocket disconnected from %@", webSocket.url);
    connected = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:WSJSON_DISCONNECTED object:nil];
    [self onError];
}

- (void) didTimeout {
    [self cancelTimeoutTimer];
    NSLog(@"websocket connection timed out");
    [self webSocket:socket didFailWithError:[NSError errorWithDomain:@"ru.limehat.ios.intelsound" code:5 userInfo:@{NSLocalizedDescriptionKey:@"connection timed out"}]];
}

- (void) cancelTimeoutTimer {
    if(!timeoutTimer)
        return;
    [timeoutTimer invalidate];
    timeoutTimer = nil;
}

- (void) resendQueue {
    if(!connected)
        return;
    for(NSString* request in requestsQueue)
        [socket send:request];
    [requestsQueue removeAllObjects];
}

- (void) onError {
    [self cancelTimeoutTimer];
    for(WSJsonErrback errback in errbacks.allValues) {
        if(errback)
            errback(nil);
    }
    [errbacks removeAllObjects];
    // как только пропало соединение пытаемся его восстановить
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self reconnect];
    });
}

- (void) reconnect {
    socket.delegate = nil;
    [socket close];
    [self cancelTimeoutTimer];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:serverUrl]];
    if(cert) {
        NSData* certData = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:cert ofType:@"der"]];
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certData);
        request.SR_SSLPinnedCertificates = @[(__bridge id)certificate];
    }
    socket = [[SRWebSocket alloc] initWithURLRequest:request];
    socket.delegate = self;
//    NSDate* futureDate = [NSDate dateWithTimeIntervalSinceNow:timeout];
//    timeoutTimer = [[NSTimer alloc] initWithFireDate:futureDate interval:0 target:self selector:@selector(didTimeout) userInfo:nil repeats:NO];
    timeoutTimer = [NSTimer timerWithTimeInterval:timeout target:self selector:@selector(didTimeout) userInfo:nil repeats:NO];
//    [[NSRunLoop SR_networkRunLoop] addTimer:timeoutTimer forMode:NSDefaultRunLoopMode];
    [socket open];
}

#pragma mark private methods
- (id) init {
    self = [super init];
    if(self){
        requestsQueue = [NSMutableArray new];
        callbacks = [NSMutableDictionary new];
        errbacks = [NSMutableDictionary new];
    }
    return self;
}

@end
