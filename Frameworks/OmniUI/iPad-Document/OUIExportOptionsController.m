// Copyright 2010-2015 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//

#import "OUIExportOptionsController.h"

#import <OmniDAV/ODAVFileInfo.h>
#import <OmniDocumentStore/ODSFileItem.h>
#import <OmniFileExchange/OFXServerAccount.h>
#import <OmniFileExchange/OFXServerAccountType.h>
#import <OmniFoundation/OFCredentials.h>
#import <OmniFoundation/OFUTI.h>
#import <OmniUI/OUIAppController+InAppStore.h>
#import <OmniUI/OUIBarButtonItem.h>
#import <OmniUI/OUIInAppStoreViewController.h>
#import <OmniUI/OUIOverlayView.h>
#import <OmniUI/UIView-OUIExtensions.h>
#import <OmniUIDocument/OUIDocumentAppController.h>
#import <OmniUIDocument/OUIDocumentPicker.h>
#import <OmniUIDocument/OUIDocumentPickerViewController.h>
#import <OmniUnzip/OUZipArchive.h>

#import "OUIWebDAVSyncListController.h"
#import "OUIExportOptionViewCell.h"
#import "OUIExportOptionsCollectionViewLayout.h"

RCS_ID("$Id$")


#pragma mark - OUIExportOption
// This is a model class used to back the options added to the collection view. The OUIExportOptionsController creates these so their is currently no reason to make this a public class.
@interface OUIExportOption : NSObject

@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *exportType;

@end
@implementation OUIExportOption
@end

#pragma mark - OUIExportOptionsController
@interface OUIExportOptionsController () <UICollectionViewDataSource, UICollectionViewDelegate> //<OFSFileManagerDelegate>

@property (weak, nonatomic) IBOutlet UICollectionView *collectionView;
@property (weak, nonatomic) IBOutlet UILabel *exportDescriptionLabel;
@property (weak, nonatomic) IBOutlet UILabel *exportDestinationLabel;
@property (weak, nonatomic) IBOutlet UIButton *inAppPurchaseButton;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *collectionViewTrailingConstraint;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bottomViewsTrailingConstraint;
@property (weak, nonatomic) IBOutlet UIView *bottomViewsContainerView;

@property (nonatomic, strong) UIDocumentInteractionController *documentInteractionController;

@end


@implementation OUIExportOptionsController
{
    OFXServerAccount *_serverAccount;
    OUIExportOptionsType _exportType;
    
    // Model level objects to represent options in collection view.
    NSMutableArray *_exportOptions;
    
    UIView *_fileConversionOverlayView;
    CGRect _rectForExportOptionButtonChosen;
    
    BOOL _needsToCheckInAppPurchaseAvailability;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil;
{
    return [super initWithNibName:@"OUIExportOptions" bundle:OMNI_BUNDLE];
}

- (id)initWithServerAccount:(OFXServerAccount *)serverAccount exportType:(OUIExportOptionsType)exportType;
{
    if (!(self = [super initWithNibName:nil bundle:nil]))
        return nil;
    
    self.automaticallyAdjustsScrollViewInsets = YES;
    _serverAccount = serverAccount;
    _exportType = exportType;
    
    return self;
}

- (void)dealloc;
{
    _documentInteractionController.delegate = nil;
}

#pragma mark - UIViewController subclass
static NSString * const exportOptionCellReuseIdentifier = @"exportOptionCell";

- (void)viewDidLoad;
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];

    // Need to constrain this manually because we're not in a storyboard and so don't have a for-real topLayoutGuide
    [NSLayoutConstraint constraintWithItem:self.exportDescriptionLabel attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.topLayoutGuide attribute:NSLayoutAttributeBottom multiplier:1.0 constant:20.0].active = YES;

    UIBarButtonItem *cancel = [[OUIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(_cancel:)];
    self.navigationItem.leftBarButtonItem = cancel;
    
    self.navigationItem.title = NSLocalizedStringFromTableInBundle(@"Choose Format", @"OmniUIDocument", OMNI_BUNDLE, @"export options title");
    
    self.collectionView.backgroundColor = [UIColor whiteColor];
    [self.collectionView registerNib:[UINib nibWithNibName:@"OUIExportOptionViewCell" bundle:nil] forCellWithReuseIdentifier:exportOptionCellReuseIdentifier];
    if ([self.collectionView.collectionViewLayout isKindOfClass:[OUIExportOptionsCollectionViewLayout class]]) {
        OUIExportOptionsCollectionViewLayout *layout =((OUIExportOptionsCollectionViewLayout *)(self.collectionView.collectionViewLayout));
        layout.minimumInterItemSpacing = 0.0;
    }
    
    _exportOptions = [[NSMutableArray alloc] init];
    [self _reloadExportTypes];
}

- (void)viewWillAppear:(BOOL)animated;
{
    [super viewWillAppear:animated];

    OUIDocumentPickerViewController *picker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
    ODSFileItem *fileItem = picker.singleSelectedFileItem;
    OBASSERT(fileItem != nil);
    NSString *docName = fileItem.name;
    
    NSString *actionDescription = nil;
    if (_exportType == OUIExportOptionsEmail) {
        self.navigationItem.title = NSLocalizedStringFromTableInBundle(@"Send via Mail", @"OmniUIDocument", OMNI_BUNDLE, @"export options title");
        
        _exportDestinationLabel.text = nil;
        
        actionDescription = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Choose a format for emailing \"%@\":", @"OmniUIDocument", OMNI_BUNDLE, @"email action description"), docName, nil];
    }
    else if (_exportType == OUIExportOptionsSendToApp) {
        _exportDestinationLabel.text = nil;
        
        actionDescription = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Send \"%@\" to app as:", @"OmniUIDocument", OMNI_BUNDLE, @"send to app description"), docName, nil];
    }
    else if (_exportType == OUIExportOptionsExport) {
        if (OFISEQUAL(_serverAccount.type.identifier, OFXiTunesLocalDocumentsServerAccountTypeIdentifier)) {
            _exportDestinationLabel.text = nil;
        } else {
            NSString *addressString = [_serverAccount.remoteBaseURL absoluteString];
            _exportDestinationLabel.text = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Server address: %@", @"OmniUIDocument", OMNI_BUNDLE, @"email action description"), addressString, nil];
        }
                
        actionDescription = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Export \"%@\" to %@ as:", @"OmniUIDocument", OMNI_BUNDLE, @"export action description"), docName, _serverAccount.displayName, nil];
    }
    
    _exportDescriptionLabel.text = actionDescription;
    
    _rectForExportOptionButtonChosen = CGRectZero;
}

-(void)updateViewConstraints;
{
    // This code manipulates the bottom of the collection view and the container view that contains the "buy pro" and "where are we uploading" views, so that only the relevant views show and the collection view eats as much vertical space as possible.
    if (![_inAppPurchaseButton isHidden] && _exportDestinationLabel.text) {
        [self.view removeConstraint:self.collectionViewTrailingConstraint];
        self.collectionViewTrailingConstraint = [NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.bottomViewsContainerView attribute:NSLayoutAttributeTop multiplier:1.0 constant:0];
        [self.view addConstraint:self.collectionViewTrailingConstraint];
        self.bottomViewsTrailingConstraint.constant = 0;
        self.exportDestinationLabel.hidden = NO;
    } else if (![_inAppPurchaseButton isHidden]) {
        [self.view removeConstraint:self.collectionViewTrailingConstraint];
        self.collectionViewTrailingConstraint = [NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.bottomViewsContainerView attribute:NSLayoutAttributeTop multiplier:1.0 constant:0];
        [self.view addConstraint:self.collectionViewTrailingConstraint];

        self.bottomViewsTrailingConstraint.constant = -8; //the empty text label collapses down, so we only need to account for the extra 8 pts of padding between the label & button.
        self.exportDestinationLabel.hidden = YES;
    } else if (_exportDestinationLabel.text) {
        [self.view removeConstraint:self.collectionViewTrailingConstraint];
        self.collectionViewTrailingConstraint = [NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.exportDestinationLabel attribute:NSLayoutAttributeTop multiplier:1.0 constant:-8.0]; // -8.0 to give the expected padding above the export destination label
        [self.view addConstraint:self.collectionViewTrailingConstraint];
        self.bottomViewsTrailingConstraint.constant = 0;
        self.exportDestinationLabel.hidden = NO;
    } else {
        [self.view removeConstraint:self.collectionViewTrailingConstraint];
        self.collectionViewTrailingConstraint = [NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0];
        [self.view addConstraint:self.collectionViewTrailingConstraint];

    }

    [super updateViewConstraints];
}

- (BOOL)shouldAutorotate;
{
    return YES;
}

#pragma mark - API

- (void)exportFileWrapper:(NSFileWrapper *)fileWrapper;
{
    [self _foreground_enableInterfaceAfterExportConversion];
    
    __autoreleasing NSError *error = nil;
    OUIWebDAVSyncListController *syncListController = [[OUIWebDAVSyncListController alloc] initWithServerAccount:_serverAccount exporting:YES error:&error];
    if (!syncListController) {
        OUI_PRESENT_ERROR(error);
        return;
    }
    
    syncListController.exportFileWrapper = fileWrapper;
    
    [self.navigationController pushViewController:syncListController animated:YES];
}

#pragma mark - UICollectionViewDataSource
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section;
{
    return [_exportOptions count];
}

// The cell that is returned must be retrieved from a call to -dequeueReusableCellWithReuseIdentifier:forIndexPath:
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath;
{
    OUIExportOption *option = _exportOptions[indexPath.item];
    
    OUIExportOptionViewCell *cell = (OUIExportOptionViewCell *)[collectionView dequeueReusableCellWithReuseIdentifier:exportOptionCellReuseIdentifier forIndexPath:indexPath];

    [cell.imageView setImage:option.image];
    [cell.label setText:option.label];

    return cell;
}

#pragma mark - UICollectionViewDelegate
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath;
{
    OUIExportOptionViewCell *cell = (OUIExportOptionViewCell *)[collectionView cellForItemAtIndexPath:indexPath];
    _rectForExportOptionButtonChosen = cell.frame;
    
    OUIExportOption *selectedOption = _exportOptions[indexPath.item];
    
    
    NSString *storeIdentifier = nil;
    OUIDocumentPickerViewController *picker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
    ODSFileItem *fileItem = picker.singleSelectedFileItem;
    OBASSERT(fileItem != nil);
    NSArray *inAppPurchaseExportTypes = [picker availableInAppPurchaseExportTypesForFileItem:fileItem serverAccount:_serverAccount exportOptionsType:_exportType];
    if ([inAppPurchaseExportTypes count] > 0) {
        OBASSERT([inAppPurchaseExportTypes count] == 1);    // only support for one in-app export type
        storeIdentifier = [inAppPurchaseExportTypes objectAtIndex:0];
    }

    if (OFISNULL(selectedOption.exportType) || (![selectedOption.exportType isEqualToString:storeIdentifier])) {
        [self _performActionForExportOption:selectedOption];
    }
    else {
        [self _performActionForInAppPurchaseExportOption:selectedOption];
    }
}

#pragma mark - Private

- (IBAction)_cancel:(id)sender;
{
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)_foreground_exportFileWrapper:(NSFileWrapper *)fileWrapper;
{
    OBPRECONDITION([NSThread isMainThread]);
    
    if (_exportType != OUIExportOptionsSendToApp) {
        [self exportFileWrapper:fileWrapper];
        return;
    }
    
    // Write to temp folder (need URL of file on disk to pass off to Doc Interaction.)
    NSString *temporaryDirectory = NSTemporaryDirectory();
    NSString *tempPath = [temporaryDirectory stringByAppendingPathComponent:[fileWrapper preferredFilename]];
    NSURL *tempURL = nil;
    
    if ([fileWrapper isDirectory]) {
        // We need to zip this mother up!
        NSString *tempZipPath = [tempPath stringByAppendingPathExtension:@"zip"];
        
        @autoreleasepool {
            __autoreleasing NSError *error = nil;
            if (![OUZipArchive createZipFile:tempZipPath fromFileWrappers:[NSArray arrayWithObject:fileWrapper] error:&error]) {
                OUI_PRESENT_ERROR(error);
                return;
            }
        }

        tempURL = [NSURL fileURLWithPath:tempZipPath];
    } else {
        tempURL = [NSURL fileURLWithPath:tempPath isDirectory:[fileWrapper isDirectory]];
        
        // Get a FileManager for our Temp Directory.
        __autoreleasing NSError *error = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];

        // If the temp file exists, we delete it.
        if ([fileManager fileExistsAtPath:[tempURL path]]) {
            if (![fileManager removeItemAtURL:tempURL error:&error]) {
                OUI_PRESENT_ERROR(error);
                return;
            }
        }
        
        // Write to temp dir.
        if (![fileWrapper writeToURL:tempURL options:0 originalContentsURL:nil error:&error]) {
            OUI_PRESENT_ERROR(error);
            return;
        }
    }
    
    [self _foreground_enableInterfaceAfterExportConversion];
    
    // By now we have written the project out to a temp dir. Time to handoff to Doc Interaction.
    self.documentInteractionController = [UIDocumentInteractionController interactionControllerWithURL:tempURL];
    self.documentInteractionController.delegate = self;
    BOOL didOpen = [self.documentInteractionController presentOpenInMenuFromRect:_rectForExportOptionButtonChosen inView:_collectionView animated:YES];
    if (didOpen == NO) {
        // Show Activity View Controller instead.
        UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[tempURL] applicationActivities:nil];
        activityViewController.modalPresentationStyle = UIModalPresentationPopover;
        activityViewController.popoverPresentationController.sourceRect = _rectForExportOptionButtonChosen;
        activityViewController.popoverPresentationController.sourceView = _collectionView;
        [self presentViewController:activityViewController animated:YES completion:nil];
    }
}

- (void)_foreground_exportDocumentOfType:(NSString *)fileType;
{
    OBPRECONDITION([NSThread isMainThread]);
    @autoreleasepool {
        OUIDocumentPickerViewController *documentPicker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
        ODSFileItem *fileItem = documentPicker.singleSelectedFileItem;
        if (!fileItem) {
            OBASSERT_NOT_REACHED("no selected document");
            [self _foreground_enableInterfaceAfterExportConversion];
            return;
        }
        
        [documentPicker exportFileWrapperOfType:fileType forFileItem:fileItem withCompletionHandler:^(NSFileWrapper *fileWrapper, NSError *error) {
            // Need to make sure all of this happens on the main thread.
            main_async(^{
                if (fileWrapper == nil) {
                    OUI_PRESENT_ERROR(error);
                    [self _foreground_enableInterfaceAfterExportConversion];
                } else {
                    [self _foreground_exportFileWrapper:fileWrapper];
                }
            });
        }];
    }
}

- (void)_setInterfaceDisabledWhileExporting:(BOOL)shouldDisable;
{
    self.navigationItem.leftBarButtonItem.enabled = !shouldDisable;
    self.navigationItem.rightBarButtonItem.enabled = !shouldDisable;
    self.view.userInteractionEnabled = !shouldDisable;
    
    
    if (shouldDisable) {
        OBASSERT_NULL(_fileConversionOverlayView)
        _fileConversionOverlayView = [[UIView alloc] initWithFrame:_collectionView.frame];
        _fileConversionOverlayView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
        [self.view addSubview:_fileConversionOverlayView];
        
        UIActivityIndicatorView *fileConversionActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        // Figure out center of overlay view.
        CGPoint overlayCenter = _fileConversionOverlayView.center;
        CGPoint actualCenterForActivityIndicator = (CGPoint){
            .x = overlayCenter.x - _fileConversionOverlayView.frame.origin.x,
            .y = overlayCenter.y - _fileConversionOverlayView.frame.origin.y
        };
        
        fileConversionActivityIndicator.center = actualCenterForActivityIndicator;
        
        [_fileConversionOverlayView addSubview:fileConversionActivityIndicator];
        [fileConversionActivityIndicator startAnimating];
    }
    else {
        OBASSERT_NOTNULL(_fileConversionOverlayView);
        [_fileConversionOverlayView removeFromSuperview];
        _fileConversionOverlayView = nil;
    }
}

- (void)_foreground_disableInterfaceForExportConversion;
{
    OBPRECONDITION([NSThread isMainThread]);
    [self _setInterfaceDisabledWhileExporting:YES];
}
- (void)_foreground_enableInterfaceAfterExportConversion;
{
    OBPRECONDITION([NSThread isMainThread]);
    [self _setInterfaceDisabledWhileExporting:NO];
}

- (void)_beginBackgroundExportDocumentOfType:(NSString *)fileType;
{
    [self _foreground_disableInterfaceForExportConversion];
    [self performSelector:@selector(_foreground_exportDocumentOfType:) withObject:fileType afterDelay:0.0];
    //[self _foreground_exportDocumentOfType:fileType];
}

- (void)_foreground_finishBackgroundEmailExportWithExportType:(NSString *)exportType fileWrapper:(NSFileWrapper *)fileWrapper;
{
    OBPRECONDITION([NSThread isMainThread]);
    [self _foreground_enableInterfaceAfterExportConversion];
    
    if (fileWrapper) {
        [self.navigationController dismissViewControllerAnimated:YES completion:^{
            OUIDocumentPickerViewController *documentPicker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
            [documentPicker sendEmailWithFileWrapper:fileWrapper forExportType:exportType];
        }];
    }
}

- (void)_foreground_emailExportOfType:(NSString *)exportType;
{
    OBPRECONDITION([NSThread isMainThread]);
    
    @autoreleasepool {
        if (OFISNULL(exportType)) {
            // The fileType being null means that the user selected the OO3 file. This does not require a conversion.
            [self.navigationController dismissViewControllerAnimated:YES completion:^{
                [[[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController] emailDocument:nil];
            }];
            return;
        }
        
        OUIDocumentPickerViewController *documentPicker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
        ODSFileItem *fileItem = documentPicker.singleSelectedFileItem;
        if (!fileItem) {
            OBASSERT_NOT_REACHED("no selected document");
            [self _foreground_enableInterfaceAfterExportConversion];
            return;
        }
        
        [documentPicker exportFileWrapperOfType:exportType forFileItem:fileItem withCompletionHandler:^(NSFileWrapper *fileWrapper, NSError *error) {
            if (fileWrapper == nil) {
                OUI_PRESENT_ERROR(error);
                [self _foreground_enableInterfaceAfterExportConversion];
            }
            else {
                [self _foreground_finishBackgroundEmailExportWithExportType:exportType fileWrapper:fileWrapper];
            }
        }];
    }
}

- (void)_performActionForExportOption:(OUIExportOption *)option;
{
    NSString *exportType = option.exportType;
    
    if (_exportType == OUIExportOptionsEmail) {
        [self _foreground_disableInterfaceForExportConversion];
        [self _foreground_emailExportOfType:exportType];
    } else {
        [self _beginBackgroundExportDocumentOfType:exportType];
    }
}

- (void)_performActionForInAppPurchaseExportOption:(id)sender;
{
    _needsToCheckInAppPurchaseAvailability = YES;
    OUIDocumentPickerViewController *picker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reloadExportTypes:) name:OUIInAppStoreViewControllerUpgradeInstalledNotification object:nil];
    
    if ([sender isKindOfClass:[OUIExportOption class]]) {
        OUIExportOption *option = (OUIExportOption *)sender;
        [picker purchaseExportType:option.exportType navigationController:self.navigationController];
    } else if (sender == _inAppPurchaseButton) {
        ODSFileItem *fileItem = picker.singleSelectedFileItem;
        NSArray *inAppPurchaseExportTypes = [picker availableInAppPurchaseExportTypesForFileItem:fileItem serverAccount:_serverAccount exportOptionsType:_exportType];
        OBASSERT([inAppPurchaseExportTypes count] == 1);    // only support for one in-app export type
        NSString *exportType = [inAppPurchaseExportTypes objectAtIndex:0];
        [picker purchaseExportType:exportType navigationController:self.navigationController];
    } else {
        OBASSERT_NOT_REACHED("unknown sender");
    }
}

- (void)_reloadExportTypes;
{
    
    OUIDocumentPickerViewController *picker = [[[OUIDocumentAppController controller] documentPicker] selectedScopeViewController];
    
    ODSFileItem *fileItem = picker.singleSelectedFileItem;
    
    [_exportOptions removeAllObjects];
    
    NSArray *exportTypes = [picker availableExportTypesForFileItem:fileItem serverAccount:_serverAccount exportOptionsType:_exportType];
    for (NSString *exportType in exportTypes) {
        
        UIImage *iconImage = nil;
        NSString *label = nil;
        
        
        if (OFISNULL(exportType)) {
            // NOTE: Adding the native type first with a null (instead of a its non-null actual type) is important for doing exports of documents exactly as they are instead of going through the exporter. Ideally both cases would be the same, but in OO/iPad the OO3 "export" path (as opposed to normal "save") has the ability to strip hidden columns, sort sorts, calculate summary values and so on for the benefit of the XSL-based exporters. If we want "export" to the OO file format to not perform these transformations, we'll need to add flags on the OOXSLPlugin to say whether the target wants them pre-applied or not.
            NSURL *documentURL = fileItem.fileURL;
            OBFinishPortingLater("<bug:///75843> (Add a UTI property to ODSFileItem)");
            NSString *fileUTI = OFUTIForFileExtensionPreferringNative([documentURL pathExtension], nil); // NSString *fileUTI = [ODAVFileInfo UTIForURL:documentURL];
            iconImage = [picker exportIconForUTI:fileUTI];
            
            label = [picker exportLabelForUTI:fileUTI];
            if (label == nil) {
                label = [[documentURL path] pathExtension];
            }
        }
        else {
            iconImage = [picker exportIconForUTI:exportType];
            label = [picker exportLabelForUTI:exportType];
        }
        
        OUIExportOption *option = [[OUIExportOption alloc] init];
        option.image = iconImage;
        option.label = label;
        option.exportType = exportType;
        
        [_exportOptions addObject:option];
    }
    
    NSArray *inAppPurchaseExportTypes = [picker availableInAppPurchaseExportTypesForFileItem:fileItem serverAccount:_serverAccount exportOptionsType:_exportType];
    if ([inAppPurchaseExportTypes count] > 0) {
        OBASSERT([inAppPurchaseExportTypes count] == 1);    // only support for one in-app export type
        NSString *exportType = [inAppPurchaseExportTypes objectAtIndex:0];
        
        NSString *label = [picker purchaseDescriptionForExportType:exportType];
        NSString *purchaseNowLocalized = NSLocalizedStringFromTableInBundle(@"Purchase Now.", @"OmniUIDocument", OMNI_BUNDLE, @"purchase now button title");
        NSString *buttonTitle = [NSString stringWithFormat:@"%@ %@", label, purchaseNowLocalized];
        [_inAppPurchaseButton setTitle:buttonTitle forState:UIControlStateNormal];
        
        [_inAppPurchaseButton setHidden:NO];
    } else {
        [_inAppPurchaseButton setHidden:YES];
    }
    
    if (![_inAppPurchaseButton isHidden])
        [_inAppPurchaseButton addTarget:self action:@selector(_performActionForInAppPurchaseExportOption:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)_reloadExportTypes:(NSNotification *)notification;
{
    [self _reloadExportTypes];
    [self.collectionView reloadData];
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (void)documentInteractionController:(UIDocumentInteractionController *)controller willBeginSendingToApplication:(NSString *)application;
{
    [self dismissViewControllerAnimated:NO completion:nil];
}

@end
