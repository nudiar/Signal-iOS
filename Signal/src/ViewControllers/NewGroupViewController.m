//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "NewGroupViewController.h"
#import "AddToGroupViewController.h"
#import "AvatarViewHelper.h"
#import "BlockListUIUtils.h"
#import "ContactTableViewCell.h"
#import "ContactsViewHelper.h"
#import "Environment.h"
#import "NSString+OWS.h"
#import "OWSContactsManager.h"
#import "OWSNavigationController.h"
#import "OWSTableViewController.h"
#import "Signal-Swift.h"
#import "SignalKeyingStorage.h"
#import "TSOutgoingMessage.h"
#import "UIUtil.h"
#import "UIView+OWS.h"
#import "UIViewController+OWS.h"
#import <SignalServiceKit/NSDate+OWS.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/SecurityUtils.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/TSGroupModel.h>
#import <SignalServiceKit/TSGroupThread.h>

NS_ASSUME_NONNULL_BEGIN

const NSUInteger kNewGroupViewControllerAvatarWidth = 68;

@interface NewGroupViewController () <UIImagePickerControllerDelegate,
    UITextFieldDelegate,
    ContactsViewHelperDelegate,
    AvatarViewHelperDelegate,
    AddToGroupViewControllerDelegate,
    OWSTableViewControllerDelegate,
    UINavigationControllerDelegate,
    OWSNavigationView>

@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;
@property (nonatomic, readonly) AvatarViewHelper *avatarViewHelper;

@property (nonatomic, readonly) OWSTableViewController *tableViewController;
@property (nonatomic, readonly) AvatarImageView *avatarView;
@property (nonatomic, readonly) UITextField *groupNameTextField;

@property (nonatomic, nullable) UIImage *groupAvatar;
@property (nonatomic) NSMutableSet<NSString *> *memberRecipientIds;

@property (nonatomic) BOOL hasUnsavedChanges;
@property (nonatomic) BOOL hasAppeared;

@end

#pragma mark -

@implementation NewGroupViewController

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (void)commonInit
{
    _messageSender = [Environment getCurrent].messageSender;
    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];
    _avatarViewHelper = [AvatarViewHelper new];
    _avatarViewHelper.delegate = self;

    self.memberRecipientIds = [NSMutableSet new];
}

#pragma mark - View Lifecycle

- (void)loadView
{
    [super loadView];

    self.title = [MessageStrings newGroupDefaultTitle];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedString(@"NEW_GROUP_CREATE_BUTTON", @"The title for the 'create group' button.")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(createGroup)];
    self.navigationItem.rightBarButtonItem.imageInsets = UIEdgeInsetsMake(0, -10, 0, 10);
    self.navigationItem.rightBarButtonItem.accessibilityLabel
        = NSLocalizedString(@"FINISH_GROUP_CREATION_LABEL", @"Accessibilty label for finishing new group");

    // First section.

    UIView *firstSection = [self firstSectionHeader];
    [self.view addSubview:firstSection];
    [firstSection autoSetDimension:ALDimensionHeight toSize:100.f];
    [firstSection autoPinWidthToSuperview];
    [firstSection autoPinEdgeToSuperviewEdge:ALEdgeTop];

    _tableViewController = [OWSTableViewController new];
    _tableViewController.delegate = self;
    [self.view addSubview:self.tableViewController.view];
    [_tableViewController.view autoPinWidthToSuperview];
    [_tableViewController.view autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:firstSection];
    [_tableViewController.view autoPinEdgeToSuperviewEdge:ALEdgeBottom];

    [self updateTableContents];
}

- (UIView *)firstSectionHeader
{
    UIView *firstSectionHeader = [UIView new];
    firstSectionHeader.userInteractionEnabled = YES;
    [firstSectionHeader
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(headerWasTapped:)]];
    firstSectionHeader.backgroundColor = [UIColor whiteColor];
    UIView *threadInfoView = [UIView new];
    [firstSectionHeader addSubview:threadInfoView];
    [threadInfoView autoPinWidthToSuperviewWithMargin:16.f];
    [threadInfoView autoPinHeightToSuperviewWithMargin:16.f];

    AvatarImageView *avatarView = [AvatarImageView new];
    _avatarView = avatarView;

    [threadInfoView addSubview:avatarView];
    [avatarView autoVCenterInSuperview];
    [avatarView autoPinLeadingToSuperview];
    [avatarView autoSetDimension:ALDimensionWidth toSize:kNewGroupViewControllerAvatarWidth];
    [avatarView autoSetDimension:ALDimensionHeight toSize:kNewGroupViewControllerAvatarWidth];
    [self updateAvatarView];

    UITextField *groupNameTextField = [UITextField new];
    _groupNameTextField = groupNameTextField;
    groupNameTextField.textColor = [UIColor blackColor];
    groupNameTextField.font = [UIFont ows_dynamicTypeTitle2Font];
    groupNameTextField.placeholder
        = NSLocalizedString(@"NEW_GROUP_NAMEGROUP_REQUEST_DEFAULT", @"Placeholder text for group name field");
    groupNameTextField.delegate = self;
    [groupNameTextField addTarget:self
                           action:@selector(groupNameDidChange:)
                 forControlEvents:UIControlEventEditingChanged];
    [threadInfoView addSubview:groupNameTextField];
    [groupNameTextField autoVCenterInSuperview];
    [groupNameTextField autoPinTrailingToSuperview];
    [groupNameTextField autoPinLeadingToTrailingOfView:avatarView margin:16.f];

    [avatarView
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTouched:)]];
    avatarView.userInteractionEnabled = YES;

    return firstSectionHeader;
}

- (void)headerWasTapped:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self.groupNameTextField becomeFirstResponder];
    }
}

- (void)avatarTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self showChangeAvatarUI];
    }
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak NewGroupViewController *weakSelf = self;
    ContactsViewHelper *contactsViewHelper = self.contactsViewHelper;

    NSArray<SignalAccount *> *signalAccounts = self.contactsViewHelper.signalAccounts;
    NSMutableSet *nonContactMemberRecipientIds = [self.memberRecipientIds mutableCopy];
    for (SignalAccount *signalAccount in signalAccounts) {
        [nonContactMemberRecipientIds removeObject:signalAccount.recipientId];
    }

    // Non-contact Members

    if (nonContactMemberRecipientIds.count > 0 || signalAccounts.count < 1) {

        OWSTableSection *nonContactsSection = [OWSTableSection new];
        nonContactsSection.headerTitle = NSLocalizedString(
            @"NEW_GROUP_NON_CONTACTS_SECTION_TITLE", @"a title for the non-contacts section of the 'new group' view.");

        [nonContactsSection addItem:[self createAddNonContactItem]];

        for (NSString *recipientId in
            [nonContactMemberRecipientIds.allObjects sortedArrayUsingSelector:@selector(compare:)]) {

            [nonContactsSection
                addItem:[OWSTableItem itemWithCustomCellBlock:^{
                    NewGroupViewController *strongSelf = weakSelf;
                    OWSCAssert(strongSelf);

                    ContactTableViewCell *cell = [ContactTableViewCell new];
                    SignalAccount *signalAccount = [contactsViewHelper signalAccountForRecipientId:recipientId];
                    BOOL isCurrentMember = [strongSelf.memberRecipientIds containsObject:recipientId];
                    BOOL isBlocked = [contactsViewHelper isRecipientIdBlocked:recipientId];
                    if (isCurrentMember) {
                        // In the "contacts" section, we label members as such when editing an existing group.
                        cell.accessoryMessage = NSLocalizedString(
                            @"NEW_GROUP_MEMBER_LABEL", @"An indicator that a user is a member of the new group.");
                    } else if (isBlocked) {
                        cell.accessoryMessage = NSLocalizedString(
                            @"CONTACT_CELL_IS_BLOCKED", @"An indicator that a contact has been blocked.");
                    } else {
                        OWSAssert(cell.accessoryMessage == nil);
                    }

                    if (signalAccount) {
                        [cell configureWithSignalAccount:signalAccount
                                         contactsManager:contactsViewHelper.contactsManager];
                    } else {
                        [cell configureWithRecipientId:recipientId contactsManager:contactsViewHelper.contactsManager];
                    }

                    return cell;
                }
                            customRowHeight:[ContactTableViewCell rowHeight]
                            actionBlock:^{
                                BOOL isCurrentMember = [weakSelf.memberRecipientIds containsObject:recipientId];
                                BOOL isBlocked = [contactsViewHelper isRecipientIdBlocked:recipientId];
                                if (isCurrentMember) {
                                    [weakSelf removeRecipientId:recipientId];
                                } else if (isBlocked) {
                                    [BlockListUIUtils
                                        showUnblockPhoneNumberActionSheet:recipientId
                                                       fromViewController:weakSelf
                                                          blockingManager:contactsViewHelper.blockingManager
                                                          contactsManager:contactsViewHelper.contactsManager
                                                          completionBlock:^(BOOL isStillBlocked) {
                                                              if (!isStillBlocked) {
                                                                  [weakSelf addRecipientId:recipientId];
                                                              }
                                                          }];
                                } else {

                                    BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
                                        presentAlertIfNecessaryWithRecipientId:recipientId
                                                              confirmationText:NSLocalizedString(
                                                                                   @"SAFETY_NUMBER_CHANGED_CONFIRM_"
                                                                                   @"ADD_TO_GROUP_ACTION",
                                                                                   @"button title to confirm adding "
                                                                                   @"a recipient to a group when "
                                                                                   @"their safety "
                                                                                   @"number has recently changed")
                                                               contactsManager:contactsViewHelper.contactsManager
                                                                    completion:^(BOOL didConfirmIdentity) {
                                                                        if (didConfirmIdentity) {
                                                                            [weakSelf addRecipientId:recipientId];
                                                                        }
                                                                    }];
                                    if (didShowSNAlert) {
                                        return;
                                    }


                                    [weakSelf addRecipientId:recipientId];
                                }
                            }]];
        }
        [contents addSection:nonContactsSection];
    }

    // Contacts

    OWSTableSection *signalAccountSection = [OWSTableSection new];
    signalAccountSection.headerTitle = NSLocalizedString(
        @"EDIT_GROUP_CONTACTS_SECTION_TITLE", @"a title for the contacts section of the 'new/update group' view.");
    if (signalAccounts.count > 0) {

        if (nonContactMemberRecipientIds.count < 1) {
            // If the group contains any non-contacts or has not contacts,
            // the "add non-contact user" will show up in the previous section
            // of the table. However, it's more attractive to hide that section
            // for the common case where people want to create a group from just
            // their contacts.  Therefore, when that section is hidden, we want
            // to allow people to add non-contacts.
            [signalAccountSection addItem:[self createAddNonContactItem]];
        }

        for (SignalAccount *signalAccount in signalAccounts) {
            [signalAccountSection
                addItem:[OWSTableItem itemWithCustomCellBlock:^{
                    NewGroupViewController *strongSelf = weakSelf;
                    OWSCAssert(strongSelf);

                    ContactTableViewCell *cell = [ContactTableViewCell new];

                    NSString *recipientId = signalAccount.recipientId;
                    BOOL isCurrentMember = [strongSelf.memberRecipientIds containsObject:recipientId];
                    BOOL isBlocked = [contactsViewHelper isRecipientIdBlocked:recipientId];
                    if (isCurrentMember) {
                        // In the "contacts" section, we label members as such when editing an existing group.
                        cell.accessoryMessage = NSLocalizedString(
                            @"NEW_GROUP_MEMBER_LABEL", @"An indicator that a user is a member of the new group.");
                    } else if (isBlocked) {
                        cell.accessoryMessage = NSLocalizedString(
                            @"CONTACT_CELL_IS_BLOCKED", @"An indicator that a contact has been blocked.");
                    } else {
                        OWSAssert(cell.accessoryMessage == nil);
                    }

                    [cell configureWithSignalAccount:signalAccount contactsManager:contactsViewHelper.contactsManager];

                    return cell;
                }
                            customRowHeight:[ContactTableViewCell rowHeight]
                            actionBlock:^{
                                NSString *recipientId = signalAccount.recipientId;
                                BOOL isCurrentMember = [weakSelf.memberRecipientIds containsObject:recipientId];
                                BOOL isBlocked = [contactsViewHelper isRecipientIdBlocked:recipientId];
                                if (isCurrentMember) {
                                    [weakSelf removeRecipientId:recipientId];
                                } else if (isBlocked) {
                                    [BlockListUIUtils
                                        showUnblockSignalAccountActionSheet:signalAccount
                                                         fromViewController:weakSelf
                                                            blockingManager:contactsViewHelper.blockingManager
                                                            contactsManager:contactsViewHelper.contactsManager
                                                            completionBlock:^(BOOL isStillBlocked) {
                                                                if (!isStillBlocked) {
                                                                    [weakSelf addRecipientId:recipientId];
                                                                }
                                                            }];
                                } else {
                                    BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
                                        presentAlertIfNecessaryWithRecipientId:signalAccount.recipientId
                                                              confirmationText:NSLocalizedString(
                                                                                   @"SAFETY_NUMBER_CHANGED_CONFIRM_"
                                                                                   @"ADD_TO_GROUP_ACTION",
                                                                                   @"button title to confirm adding "
                                                                                   @"a recipient to a group when "
                                                                                   @"their safety "
                                                                                   @"number has recently changed")
                                                               contactsManager:contactsViewHelper.contactsManager
                                                                    completion:^(BOOL didConfirmIdentity) {
                                                                        if (didConfirmIdentity) {
                                                                            [weakSelf addRecipientId:recipientId];
                                                                        }
                                                                    }];
                                    if (didShowSNAlert) {
                                        return;
                                    }

                                    [weakSelf addRecipientId:recipientId];
                                }
                            }]];
        }
    } else {
        [signalAccountSection
            addItem:[OWSTableItem
                        softCenterLabelItemWithText:NSLocalizedString(@"SETTINGS_BLOCK_LIST_NO_CONTACTS",
                                                        @"A label that indicates the user has no Signal contacts.")]];
    }
    [contents addSection:signalAccountSection];

    self.tableViewController.contents = contents;
}

- (OWSTableItem *)createAddNonContactItem
{
    __weak NewGroupViewController *weakSelf = self;
    return [OWSTableItem
        disclosureItemWithText:NSLocalizedString(@"NEW_GROUP_ADD_NON_CONTACT",
                                   @"A label for the cell that lets you add a new non-contact member to a group.")
               customRowHeight:[ContactTableViewCell rowHeight]
                   actionBlock:^{
                       AddToGroupViewController *viewController = [AddToGroupViewController new];
                       viewController.addToGroupDelegate = weakSelf;
                       viewController.hideContacts = YES;
                       [weakSelf.navigationController pushViewController:viewController animated:YES];
                   }];
}

- (void)removeRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    [self.memberRecipientIds removeObject:recipientId];
    [self updateTableContents];
}

- (void)addRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    [self.memberRecipientIds addObject:recipientId];
    self.hasUnsavedChanges = YES;
    [self updateTableContents];
}

#pragma mark - Methods

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self.navigationController.navigationBar setTranslucent:NO];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (!self.hasAppeared) {
        [self.groupNameTextField becomeFirstResponder];
        self.hasAppeared = YES;
    }
}

#pragma mark - Actions

- (void)createGroup
{
    OWSAssert([NSThread isMainThread]);

    TSGroupModel *model = [self makeGroup];

    __block TSGroupThread *thread;
    [[TSStorageManager sharedManager].dbReadWriteConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            thread = [TSGroupThread getOrCreateThreadWithGroupModel:model transaction:transaction];
        }];
    OWSAssert(thread);
    
    [OWSProfileManager.sharedManager addThreadToProfileWhitelist:thread];

    void (^successHandler)() = ^{
        DDLogError(@"Group creation successful.");

        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:YES
                                     completion:^{
                                         // Pop to new group thread.
                                         [Environment presentConversationForThread:thread];
                                     }];

        });
    };

    void (^failureHandler)(NSError *error) = ^(NSError *error) {
        DDLogError(@"Group creation failed: %@", error);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:YES
                                     completion:^{
                                         // Add an error message to the new group indicating
                                         // that group creation didn't succeed.
                                         [[[TSErrorMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                           inThread:thread
                                                                  failedMessageType:TSErrorMessageGroupCreationFailed]
                                             save];

                                         [Environment presentConversationForThread:thread];
                                     }];
        });
    };

    [ModalActivityIndicatorViewController
        presentFromViewController:self
                        canCancel:NO
                  backgroundBlock:^(ModalActivityIndicatorViewController *modalActivityIndicator) {
                      TSOutgoingMessage *message =
                          [[TSOutgoingMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                              inThread:thread
                                                      groupMetaMessage:TSGroupMessageNew];

                      // This will save the message.
                      [message updateWithCustomMessage:NSLocalizedString(@"GROUP_CREATED", nil)];

                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                          if (model.groupImage) {
                              NSData *data = UIImagePNGRepresentation(model.groupImage);
                              DataSource *_Nullable dataSource =
                                  [DataSourceValue dataSourceWithData:data fileExtension:@"png"];
                              [self.messageSender sendAttachmentData:dataSource
                                                         contentType:OWSMimeTypeImagePng
                                                      sourceFilename:nil
                                                           inMessage:message
                                                             success:successHandler
                                                             failure:failureHandler];
                          } else {
                              [self.messageSender sendMessage:message success:successHandler failure:failureHandler];
                          }
                      });
                  }];
}

- (TSGroupModel *)makeGroup
{
    NSString *groupName = [self.groupNameTextField.text ows_stripped];
    NSMutableArray<NSString *> *recipientIds = [self.memberRecipientIds.allObjects mutableCopy];
    [recipientIds addObject:[self.contactsViewHelper localNumber]];
    NSData *groupId = [SecurityUtils generateRandomBytes:16];
    return [[TSGroupModel alloc] initWithTitle:groupName memberIds:recipientIds image:self.groupAvatar groupId:groupId];
}

#pragma mark - Group Avatar

- (void)showChangeAvatarUI
{
    [self.avatarViewHelper showChangeAvatarUI];
}

- (void)setGroupAvatar:(nullable UIImage *)groupAvatar
{
    OWSAssert([NSThread isMainThread]);

    _groupAvatar = groupAvatar;

    self.hasUnsavedChanges = YES;

    [self updateAvatarView];
}

- (void)updateAvatarView
{
    self.avatarView.image = (self.groupAvatar ?: [UIImage imageNamed:@"empty-group-avatar"]);
}

#pragma mark - Event Handling

- (void)backButtonPressed
{
    [self.groupNameTextField resignFirstResponder];

    if (!self.hasUnsavedChanges) {
        // If user made no changes, return to conversation settings view.
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    UIAlertController *controller = [UIAlertController
        alertControllerWithTitle:
            NSLocalizedString(@"NEW_GROUP_VIEW_UNSAVED_CHANGES_TITLE",
                @"The alert title if user tries to exit the new group view without saving changes.")
                         message:
                             NSLocalizedString(@"NEW_GROUP_VIEW_UNSAVED_CHANGES_MESSAGE",
                                 @"The alert message if user tries to exit the new group view without saving changes.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [controller
        addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ALERT_DISCARD_BUTTON",
                                                     @"The label for the 'discard' button in alerts and action sheets.")
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
                                             [self.navigationController popViewControllerAnimated:YES];
                                         }]];
    [controller addAction:[OWSAlerts cancelAction]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)groupNameDidChange:(id)sender
{
    self.hasUnsavedChanges = YES;
}

#pragma mark - Text Field Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self.groupNameTextField resignFirstResponder];
    return NO;
}

#pragma mark - OWSTableViewControllerDelegate

- (void)tableViewDidScroll
{
    [self.groupNameTextField resignFirstResponder];
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    [self updateTableContents];
}

- (BOOL)shouldHideLocalNumber
{
    return YES;
}

#pragma mark - AvatarViewHelperDelegate

- (NSString *)avatarActionSheetTitle
{
    return NSLocalizedString(
        @"NEW_GROUP_ADD_PHOTO_ACTION", @"Action Sheet title prompting the user for a group avatar");
}

- (void)avatarDidChange:(UIImage *)image
{
    OWSAssert(image);

    self.groupAvatar = image;
}

- (UIViewController *)fromViewController
{
    return self;
}

- (BOOL)hasClearAvatarAction
{
    return NO;
}

#pragma mark - AddToGroupViewControllerDelegate

- (void)recipientIdWasAdded:(NSString *)recipientId
{
    [self addRecipientId:recipientId];
}

- (BOOL)isRecipientGroupMember:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    return [self.memberRecipientIds containsObject:recipientId];
}

#pragma mark - OWSNavigationView

- (BOOL)shouldCancelNavigationBack
{
    BOOL result = self.hasUnsavedChanges;
    if (self.hasUnsavedChanges) {
        [self backButtonPressed];
    }
    return result;
}

@end

NS_ASSUME_NONNULL_END
