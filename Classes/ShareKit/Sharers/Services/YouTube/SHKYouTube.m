//
//  SHKYouTube.m
//  ShareKit
//
//  Created by Jacob Dunn on 2/26/13.
//
//

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import "SHKYouTube.h"
#import "SharersCommonHeaders.h"

#import "GTLRYouTube.h"
#import "GTLRUtilities.h"
#import "GTMSessionFetcher.h"
#import "GTMOAuth2ViewControllerTouch.h"

// The oauth scope we need to request at YouTube
NSString *const kYouTubeRequiredScope =  @"https://www.googleapis.com/auth/youtube";

// Keychain item name for saving the user's authentication information.
NSString *const kKeychainItemName = @"ShareKit: YouTube";

@interface SHKYouTube ()

// Accessor for the app's single instance of the service object.
@property (nonatomic, readonly) GTLRYouTubeService *youTubeService;

// Our upload
@property (nonatomic, strong) GTLRServiceTicket *uploadTicket;
@property (nonatomic, strong) NSURL *uploadLocationURL;

@end

@implementation SHKYouTube

#pragma mark -

// Get a service object with the current username/password.
//
// A "service" object handles networking tasks.  Service objects
// contain user authentication information as well as networking
// state information such as cookies set by the server in response
// to queries.

+ (GTLRYouTubeService *)youTubeService
{
    static GTLRYouTubeService *service;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[GTLRYouTubeService alloc] init];
        service.retryEnabled = YES;
    });
    return service;
}

- (GTLRYouTubeService *)youTubeService {
    return [SHKYouTube youTubeService];
}

#pragma mark -
#pragma mark Configuration : Service Definition

+ (NSString *)sharerTitle{
    return SHKLocalizedString(@"YouTube");
}

+ (BOOL)canShareFile:(SHKFile *)file
{
    NSArray *youTubeValidTypes = @[@"mov",@"m4v",@"mpeg4",@"mp4",@"avi",@"wmv",@"mpegps",@"flv",@"3gpp",@"webm"];
    
    for (NSString *extension in youTubeValidTypes) {
        if ([file.filename hasSuffix:extension]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark -
#pragma mark Configuration : Dynamic Enable

+ (BOOL)canAutoShare{
    return NO;
}

#pragma mark Authorization

- (id)init
{
    if(self = [super init]){
        GTMOAuth2Authentication *auth =
        [GTMOAuth2ViewControllerTouch authForGoogleFromKeychainForName:kKeychainItemName
                                                              clientID:SHKCONFIG(youTubeConsumerKey)
                                                          clientSecret:SHKCONFIG(youTubeSecret)];
        self.youTubeService.authorizer = auth;
    }
    return self;
}

- (BOOL)isAuthorized
{
    return ((GTMOAuth2Authentication*)self.youTubeService.authorizer).canAuthorize;
}

+(void)logout
{
    [GTMOAuth2ViewControllerTouch removeAuthFromKeychainForName:kKeychainItemName];
    
    if([SHKYouTube youTubeService].authorizer != nil){
        [GTMOAuth2ViewControllerTouch revokeTokenForGoogleAuthentication:[SHKYouTube youTubeService].authorizer];
        [SHKYouTube youTubeService].authorizer = nil;
    }
}

+ (NSString *)username {
    
    GTMOAuth2Authentication* userInfo = [SHKYouTube youTubeService].authorizer;
    NSString *result = userInfo.userEmail;
    return result;
}

#pragma mark -
#pragma mark Authorization Form

- (void)authorizationFormShow
{
    // Our completion handler
    
    __weak typeof(self) weakSelf = self;
    void (^completionHandler)(GTMOAuth2ViewControllerTouch *viewController, GTMOAuth2Authentication *auth, NSError *error) =
    ^(GTMOAuth2ViewControllerTouch *viewController, GTMOAuth2Authentication *auth, NSError *error) {
        
        // Callback
        [[SHK currentHelper] hideCurrentViewControllerAnimated:YES];
        
        if (!error) {
            weakSelf.youTubeService.authorizer = auth;
            [weakSelf authDidFinish:YES];
            [weakSelf tryPendingAction]; // Try to share again
        } else {
            [weakSelf authDidFinish:NO];
            SHKLog(@"YouTube authentication finished with error:%@", [error description]);
        }
        [[SHK currentHelper] removeSharerReference:self];
    };
    
    // Show the OAuth 2 sign-in controller.
    GTMOAuth2ViewControllerTouch *controller =
    [GTMOAuth2ViewControllerTouch controllerWithScope:kGTLRAuthScopeYouTube
                                             clientID:SHKCONFIG(youTubeConsumerKey)
                                         clientSecret:SHKCONFIG(youTubeSecret)
                                     keychainItemName:kKeychainItemName
                                    completionHandler:completionHandler];
    
    
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:SHKLocalizedString(@"Cancel")
                                                                                   style:UIBarButtonItemStyleBordered
                                                                                  target:self
                                                                                  action:@selector(authorizationCanceled:)];
    [[SHK currentHelper] showViewController:controller];
    [[SHK currentHelper] keepSharerReference:self];
}

- (void)authorizationCanceled:(id)sender
{
    GTMOAuth2ViewControllerTouch *controller = self.viewControllers[0];
    [controller cancelSigningIn];
    
    [[SHK currentHelper] hideCurrentViewControllerAnimated:YES];
    [self authDidFinish:NO];
    [[SHK currentHelper] removeSharerReference:self];
}

#pragma mark -
#pragma mark Share API Methods

- (BOOL)send
{
    if (![self validateItem]) return NO;
    
    switch (self.item.shareType) {
            
        case SHKShareTypeFile:
            [self uploadVideoFile];
            return YES;
            break;
        default:
            break;
    }
    
    return NO;
}

- (void)cancel {
    
    [self stopUpload];
    [self sendDidCancel];
}

#pragma mark - Upload

- (void)uploadVideoFile {
    
    [self displayActivity:SHKLocalizedString(@"Uploading Video...")];
    
    self.quiet = YES;
    [self sendDidStart];
    self.quiet = NO;
    
    // Collect the metadata for the upload from the item.
    
    // Status.
    GTLRYouTube_VideoStatus *status = [GTLRYouTube_VideoStatus object];
    status.privacyStatus = [self.item customValueForKey:@"privacy"];
    
    // Snippet.
    GTLRYouTube_VideoSnippet *snippet = [GTLRYouTube_VideoSnippet object];
    if(self.item.title != nil) snippet.title = self.item.title;
    if(self.item.text  != nil) snippet.descriptionProperty = self.item.text;
    if(self.item.tags  != nil) snippet.tags = self.item.tags;
    
    // TODO: Categories
    //    if ([_uploadCategoryPopup isEnabled]) {
    //        NSMenuItem *selectedCategory = [_uploadCategoryPopup selectedItem];
    //        snippet.categoryId = [selectedCategory representedObject];
    //    }
    
    GTLRYouTube_Video *video = [GTLRYouTube_Video object];
    video.status = status;
    video.snippet = snippet;
    
    [self uploadVideoWithVideoObject:video resumeUploadLocationURL:nil];
}

- (void)stopUpload{
    [self.uploadTicket cancelTicket];
    self.uploadTicket = nil;
}

- (void)restartUpload {
    // Restart a stopped upload, using the location URL from the previous
    // upload attempt
    if (_uploadLocationURL == nil) return;
    
    // Since we are restarting an upload, we do not need to add metadata to the
    // video object.
    GTLRYouTube_Video *video = [GTLRYouTube_Video object];
    
    [self uploadVideoWithVideoObject:video resumeUploadLocationURL:_uploadLocationURL];
}

- (void)uploadVideoWithVideoObject:(GTLRYouTube_Video *)video resumeUploadLocationURL:(NSURL *)locationURL {
    
    // Get a file handle for the upload data.
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.item.file.path];
    
    // Could not read file data.
    if (fileHandle == nil) {
        [self sendDidFailWithError:[SHK error:SHKLocalizedString(@"Error.")] shouldRelogin:NO];
        return;
    }
    
    // Our callback blocks ----
    
    // Completion
    void (^uploadComplete)(GTLRServiceTicket *ticket, GTLRYouTube_Video *uploadedVideo, NSError *error) =
    ^(GTLRServiceTicket *ticket, GTLRYouTube_Video *uploadedVideo, NSError *error){
        self.uploadTicket = nil;
        if (error == nil) {
            [self sendDidFinish];
        } else {
            [self sendDidFailWithError:[SHK error:SHKLocalizedString(@"The service encountered an error. Please try again later.")] shouldRelogin:NO];
        }
        self.uploadLocationURL = nil;
    };
    
    // Progress
    void (^uploadProgress)(GTLRServiceTicket *ticket, unsigned long long numberOfBytesRead, unsigned long long dataLength) =
    ^(GTLRServiceTicket *ticket, unsigned long long numberOfBytesRead, unsigned long long dataLength){
        float progress = (double)numberOfBytesRead / (double)dataLength;
        if(progress < 1)
            [self showUploadedBytes:numberOfBytesRead totalBytes:dataLength];
        else{
            [self displayActivity:SHKLocalizedString(@"Processing Video...")];
        }
        
    };
    
    // Parameters
    GTLRUploadParameters *uploadParameters = [GTLRUploadParameters uploadParametersWithFileHandle:fileHandle MIMEType:self.item.file.mimeType];
    uploadParameters.uploadLocationURL = locationURL;
    
    // Setup the upload
    
    GTLRYouTubeQuery_VideosInsert *query = [GTLRYouTubeQuery_VideosInsert queryWithObject:video part:@"snippet,status" uploadParameters:uploadParameters];
    
    // Start the upload
    self.uploadTicket = [self.youTubeService executeQuery:query completionHandler:uploadComplete];
    self.uploadTicket.service.uploadProgressBlock = uploadProgress;
    
    // TODO: Monitor application going to background/foreground to pause and resume uploads. Possibly tie into offline upload, as we may go offline mid upload
}


#pragma mark -
#pragma mark Share Form

- (NSArray *)shareFormFieldsForType:(SHKShareType)type
{
    if (type == SHKShareTypeFile)
        return @[
                 [SHKFormFieldSettings label:SHKLocalizedString(@"Title") key:@"title" type:SHKFormFieldTypeText start:self.item.title],
                 [SHKFormFieldSettings label:SHKLocalizedString(@"Text") key:@"text" type:SHKFormFieldTypeText start:self.item.text],
                 [SHKFormFieldSettings label:SHKLocalizedString(@"Tags") key:@"tags" type:SHKFormFieldTypeText start:[self.item.tags componentsJoinedByString:@","]],
                 [SHKFormFieldOptionPickerSettings label:SHKLocalizedString(@"Privacy")
                                                     key:@"privacy"
                                                   start:@"public"
                                             pickerTitle:SHKLocalizedString(@"Privacy")
                                         selectedIndexes:[[NSMutableIndexSet alloc] initWithIndex:0]
                                           displayValues:@[SHKLocalizedString(@"Public"), SHKLocalizedString(@"Private"), SHKLocalizedString(@"Unlisted")]
                                              saveValues:@[@"public", @"private", @"unlisted"]
                                           allowMultiple:NO
                                            fetchFromWeb:NO
                                                provider:nil]];
    return nil;
}

@end
